import Darwin
import FanCore
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func fmt(_ v: Double?, _ unit: String, digits: Int = 0) -> String {
    guard let v else { return "--" }
    return String(format: "%.\(digits)f%@", v, unit)
}

func printStatus(_ s: StatusSnapshot) {
    let active = s.selectedProfile == .smart ? "\(s.selectedProfile.displayName) → \(s.activeProfile.displayName)" : s.selectedProfile.displayName
    print("机型      \(s.model)\(s.dryRun ? "  [dry-run]" : "")")
    print("档位      \(active)\(s.smartReason.map { "（\($0)）" } ?? "")\(s.quietFirst ? " · 静音优先" : "")")
    print("状态      \(s.state.displayName)")
    print("温度      CPU \(fmt(s.cpuTemp, "°C", digits: 1))  GPU \(fmt(s.gpuTemp, "°C", digits: 1))  热压力 \(s.thermal.displayName)")
    print("负载      \(s.cpuLoad.map { String(format: "%.0f%%", $0 * 100) } ?? "--")  \(s.onBattery ? "电池供电" : "电源适配器")")
    for f in s.fans {
        let mode = f.manual.map { $0 ? "手动" : "自动" } ?? "?"
        let plan = f.plannedRPM.map { "  下发 \(Int($0))" } ?? "  下发 系统"
        print("风扇 \(f.index)    \(fmt(f.actualRPM, " RPM"))  SMC目标 \(fmt(f.targetRPM, ""))\(plan)  范围 \(Int(f.minRPM))–\(Int(f.maxRPM))  \(mode)")
    }
    if let e = s.lastError { print("提示      \(e)") }
}

func send(_ cmd: IPCCommand) -> StatusSnapshot {
    do { return try IPCClient().send(cmd) } catch {
        fail("\(error)（守护进程是否已安装？见 README）")
    }
}

/// 不经过守护进程，直接读取 SMC 信息，用于确认机型兼容性。只读。
func probe() {
    let hw: FanHardware
    do { hw = try FanHardware(smc: SMCConnection()) } catch { fail("\(error)") }
    print("机型       \(SystemSignals.modelIdentifier())")
    print("风扇数     \(hw.fans.count)")
    print("模式策略   \(hw.strategy)")
    print("CPU 传感器 \(hw.sensors.cpu.count) 个  GPU 传感器 \(hw.sensors.gpu.count) 个")
    let t = hw.readTemperatures()
    print("温度       CPU \(fmt(t.cpu, "°C", digits: 1))  GPU \(fmt(t.gpu, "°C", digits: 1))")
    for (spec, r) in zip(hw.fans, hw.readFans()) {
        print("风扇 \(spec.index)     \(fmt(r.actualRPM, " RPM"))  范围 \(Int(spec.minRPM))–\(Int(spec.maxRPM))  手动=\(r.manual.map(String.init) ?? "?")")
    }
    print(hw.canControl ? "结论       支持手动控制（写入需 root，可用 sudo fanctl selftest 验证）" : "结论       本机无法手动控制风扇")
}

/// 实测写入能力：短暂把风扇设到中低转速，观察实际转速是否跟随，随后无论成败都恢复自动。
func selftest() {
    guard geteuid() == 0 else { fail("selftest 需要 sudo", code: 77) }
    if (try? IPCClient(timeout: 0.5).send(.status)) != nil {
        fail("守护进程正在运行，请先切到“系统默认”档或停止服务再自检，避免两边同时写 SMC")
    }
    let hw: FanHardware
    do { hw = try FanHardware(smc: SMCConnection()) } catch { fail("\(error)") }
    guard hw.canControl, let fan = hw.fans.first else { fail("本机无法手动控制风扇") }

    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            // 信号处理里只能做最少的事：重新打开 SMC 恢复自动
            if let h = try? FanHardware(smc: SMCConnection()) { h.setAutomatic() }
            _exit(130)
        }
    }

    let target = (fan.minRPM + (fan.maxRPM - fan.minRPM) * 0.25).rounded()
    print("将风扇 \(fan.index) 设为 \(Int(target)) RPM，持续 8 秒后恢复自动……")
    var ok = false
    do {
        try hw.setManual(fan.index, rpm: target)
        for i in 1...8 {
            sleep(1)
            let a = hw.readFans().first?.actualRPM
            print("  \(i)s  实际 \(fmt(a, " RPM"))")
            if let a, abs(a - target) < target * 0.15 { ok = true }
        }
    } catch {
        print("写入失败：\(error)")
    }
    let errs = hw.setAutomatic()
    print(errs.isEmpty ? "已恢复系统自动控制" : "恢复自动时出错：\(errs)（重启电脑可强制复位）")
    print(ok ? "结果：支持手动控制 ✅" : "结果：实际转速未跟随目标，固件可能不接受手动控制 ❌")
    exit(ok ? 0 : 2)
}

let usage = """
用法：
  fanctl status                 查看当前状态
  fanctl set <档位>             切换档位：\(FanProfile.allCases.map(\.rawValue).joined(separator: " | "))
  fanctl quiet-first on|off     智能档的静音优先（图书馆/课堂）
  fanctl watch                  每 2 秒刷新状态
  fanctl probe                  只读检测本机风扇与传感器（无需守护进程）
  sudo fanctl selftest          实测本机是否接受手动转速（需先停用守护进程控制）
"""

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "status", nil:
    printStatus(send(.status))
case "set":
    guard argv.count == 2, let p = FanProfile(rawValue: argv[1]) else { fail(usage, code: 64) }
    printStatus(send(.setProfile(p)))
case "quiet-first":
    guard argv.count == 2, ["on", "off"].contains(argv[1]) else { fail(usage, code: 64) }
    printStatus(send(.setQuietFirst(argv[1] == "on")))
case "watch":
    while true {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        printStatus(send(.status))
        sleep(2)
    }
case "probe":
    probe()
case "selftest":
    selftest()
default:
    fail(usage, code: 64)
}
