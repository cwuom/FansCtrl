import FanCore
import Foundation
import os

let log = Logger(subsystem: "com.fansctrl.daemon", category: "control")

/// 风扇控制守护进程的核心。
/// 所有可变状态只在 `queue` 上读写（IPC、定时器、电源事件都会切到这个队列），因此标记为 unchecked Sendable。
final class Daemon: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.fansctrl.control", qos: .utility)
    private let hw: FanHardware?
    private let dryRun: Bool
    private let configPath: String
    private var config: DaemonConfig

    private var controller: FanController
    private var smart = SmartSelector()
    private var suppression = Suppression()
    private var suppressNote: String?
    private let cpu = CPULoadSampler()
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval = 2

    private var paused = false
    private var unsupportedReason: String?
    private var lastError: String?
    private var appliedManual = false
    private var lastWritten: [Int: Double] = [:]
    private var consecutiveFailures = 0
    /// 本次控制周期是否写过硬件；写过就重读风扇状态，避免界面显示写入前的旧值
    private var wroteHardware = false
    private let maxFailures = 3

    private var state: ControlState = .system
    private var activeProfile: FanProfile = .system
    private var temps = TemperatureReading(cpu: nil, gpu: nil)
    private var fanReadings: [FanReading] = []
    private var load: Double?
    private var onBattery = false
    private var thermal: ThermalLevel = .nominal
    private var lastRefresh: TimeInterval = -.infinity
    private let model = SystemSignals.modelIdentifier()

    init(dryRun: Bool, configPath: String) {
        self.dryRun = dryRun
        self.configPath = configPath
        self.config = DaemonConfig.load(from: configPath)
        do {
            hw = try FanHardware(smc: SMCConnection())
        } catch {
            hw = nil
            unsupportedReason = "\(error)"
        }
        let silicon = hw?.sensors.appleSilicon ?? true
        controller = FanController(tuning: silicon ? .appleSilicon : .intel)
        if let hw {
            if hw.fans.isEmpty { unsupportedReason = "未检测到风扇（无风扇机型无需控制）" }
            else if hw.strategy == .unsupported { unsupportedReason = "未找到风扇模式 key，本机固件不支持手动控制" }
            log.info("model=\(self.model, privacy: .public) fans=\(hw.fans.count) strategy=\(String(describing: hw.strategy), privacy: .public) cpuSensors=\(hw.sensors.cpu.count) gpuSensors=\(hw.sensors.gpu.count)")
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - 生命周期

    func start() {
        queue.async {
            // 上一次进程可能崩溃在手动模式下，启动先无条件交还系统
            self.releaseToSystem(force: true)
            self.reschedule()
            if self.config.profile != .system { self.tick() }
        }
    }

    /// 退出前同步交还系统控制。
    func shutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            releaseToSystem(force: true)
        }
    }

    func willSleep() {
        queue.sync {
            paused = true
            suppression.end(now: now)
            state = .paused
            releaseToSystem(force: true)
        }
    }

    func didWake() {
        queue.asyncAfter(deadline: .now() + 5) {
            self.paused = false
            self.controller.reset()
            _ = self.cpu.sample()
            self.tick()
        }
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        // 系统默认档不需要周期任务，状态按需读取，空闲时零开销；强力压制期间例外
        guard config.profile != .system || suppression.isActive else {
            state = .system
            activeProfile = .system
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - 控制循环

    private func refreshReadings() {
        guard let hw else { return }
        temps = hw.readTemperatures()
        fanReadings = hw.readFans()
        if let l = cpu.sample() { load = l }
        onBattery = SystemSignals.onBattery()
        thermal = SystemSignals.thermalLevel()
        lastRefresh = now
    }

    private func tick() {
        guard !paused, let hw else { return }
        refreshReadings()

        let profile: FanProfile
        if config.profile == .smart {
            profile = smart.step(SmartInputs(cpuLoad: load ?? 0, onBattery: onBattery, thermal: thermal,
                                             quietFirst: config.quietFirst, now: now))
        } else {
            profile = config.profile
        }
        if profile != activeProfile {
            log.info("active profile -> \(profile.rawValue, privacy: .public)")
            activeProfile = profile
        }

        guard unsupportedReason == nil, hw.canControl else {
            transition(to: .unsupported)
            releaseToSystem()
            return
        }

        let samples = hw.fans.map { spec in
            let r = fanReadings.first { $0.index == spec.index }
            // 只有自动模式下 SMC 目标转速才代表系统意图；dry-run 从不写入，风扇始终是系统控制
            return FanSample(spec: spec, actualRPM: r?.actualRPM, systemTargetRPM: r?.manual == false ? r?.targetRPM : nil)
        }
        let expired = suppression.expireIfNeeded(now: now)
        if expired { log.notice("suppression expired") }
        let decision = controller.step(profile: profile, temp: temps.control, thermal: thermal, fans: samples,
                                       now: now, suppress: suppression.isActive)
        if suppression.isActive && decision.state != .suppressed {
            // 紧急满速、过热放开、传感器异常都会提前结束压制
            suppression.end(now: now)
            suppressNote = "强力压制已提前结束：\(decision.state.displayName)"
            log.notice("suppression aborted: \(decision.state.rawValue, privacy: .public)")
        }
        transition(to: decision.state)
        wroteHardware = false
        apply(decision, hw: hw)
        if wroteHardware { fanReadings = hw.readFans() }
        // 系统默认档下压制结束后停掉定时器，回到零开销
        if !suppression.isActive && config.profile == .system && timer != nil { reschedule() }
    }

    private func transition(to s: ControlState) {
        guard s != state else { return }
        let temp = temps.control.map { String(format: "%.1f", $0) } ?? "nil"
        log.notice("state \(self.state.rawValue, privacy: .public) -> \(s.rawValue, privacy: .public) temp=\(temp, privacy: .public)")
        state = s
    }

    private func apply(_ decision: ControlDecision, hw: FanHardware) {
        guard let targets = decision.targets else {
            releaseToSystem()
            return
        }
        if dryRun {
            lastWritten = targets
            appliedManual = true
            return
        }
        // 系统（thermalmonitord）可能把风扇抢回自动模式：重新下发，连续发生则判定不支持
        let overridden = appliedManual && fanReadings.contains { $0.manual == false }
        if overridden {
            lastWritten = [:]
            recordFailure("风扇模式被系统改回自动")
            if unsupportedReason != nil { return }
        }
        for (index, rpm) in targets.sorted(by: { $0.key < $1.key }) where lastWritten[index] != rpm {
            // 先标记：即使写到一半失败（模式已切手动），之后也一定会执行恢复
            appliedManual = true
            do {
                wroteHardware = true
                try hw.setManual(index, rpm: rpm)
                lastWritten[index] = rpm
            } catch {
                recordFailure("\(error)")
                return
            }
        }
        if !overridden { consecutiveFailures = 0 }
    }

    private func recordFailure(_ message: String) {
        lastError = message
        consecutiveFailures += 1
        log.error("control failure #\(self.consecutiveFailures): \(message, privacy: .public)")
        if consecutiveFailures >= maxFailures {
            unsupportedReason = "连续 \(maxFailures) 次控制失败，已停止接管：\(message)"
            transition(to: .unsupported)
            releaseToSystem(force: true)
        }
    }

    private func releaseToSystem(force: Bool = false) {
        guard force || appliedManual || !lastWritten.isEmpty else { return }
        if !dryRun, let hw {
            wroteHardware = true
            for e in hw.setAutomatic() {
                lastError = "\(e)"
                log.error("restore auto failed: \(String(describing: e), privacy: .public)")
            }
        }
        appliedManual = false
        lastWritten = [:]
    }

    // MARK: - 命令

    func handle(_ cmd: IPCCommand) -> IPCResponse {
        queue.sync {
            switch cmd {
            case .status:
                break
            case .setProfile(let p):
                guard p != config.profile else { break }
                log.notice("profile set to \(p.rawValue, privacy: .public)")
                config.profile = p
                persist()
                controller.reset()
                smart = SmartSelector()
                if p == .system {
                    releaseToSystem(force: true)
                    refreshReadings()
                }
                reschedule()
                // 立即执行一次，让返回给界面的状态就是新档位的结果
                if p != .system { tick() }
            case .setSuppress(true):
                guard unsupportedReason == nil, hw?.canControl == true else {
                    return IPCResponse(ok: false, error: "本机不支持手动控制风扇，无法强力压制", status: snapshot())
                }
                switch suppression.start(now: now) {
                case .started:
                    log.notice("suppression started")
                    suppressNote = nil
                    if timer == nil { reschedule() }
                    tick()
                case .alreadyActive:
                    break
                case .coolingDown(let remaining):
                    return IPCResponse(ok: false, error: "强力压制冷却中，\(Int(remaining.rounded(.up))) 秒后可再次开启",
                                       status: snapshot())
                }
            case .setSuppress(false):
                guard suppression.isActive else { break }
                suppression.end(now: now)
                log.notice("suppression cancelled")
                tick()
            case .setQuietFirst(let v):
                guard v != config.quietFirst else { break }
                config.quietFirst = v
                persist()
                // 立即重新选档，让返回给界面的状态就是切换后的结果
                if config.profile == .smart { tick() }
            }
            return IPCResponse(ok: true, status: snapshot())
        }
    }

    private func persist() {
        do { try config.save(to: configPath) } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
            log.error("save config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func snapshot() -> StatusSnapshot {
        if timer == nil && now - lastRefresh > 1 { refreshReadings() }
        let fans: [FanStatus] = (hw?.fans ?? []).map { spec in
            let r = fanReadings.first { $0.index == spec.index }
            return FanStatus(index: spec.index, actualRPM: r?.actualRPM, targetRPM: r?.targetRPM,
                             minRPM: spec.minRPM, maxRPM: spec.maxRPM, manual: r?.manual,
                             plannedRPM: lastWritten[spec.index])
        }
        return StatusSnapshot(
            model: model,
            selectedProfile: config.profile,
            activeProfile: activeProfile,
            smartReason: config.profile == .smart ? smart.reason : nil,
            quietFirst: config.quietFirst,
            state: unsupportedReason != nil ? .unsupported : state,
            cpuTemp: temps.cpu,
            gpuTemp: temps.gpu,
            controlTemp: temps.control,
            cpuLoad: load,
            onBattery: onBattery,
            thermal: thermal,
            fans: fans,
            controlSupported: unsupportedReason == nil && (hw?.canControl ?? false),
            dryRun: dryRun,
            lastError: unsupportedReason ?? lastError,
            suppressRemaining: suppression.remaining(now: now),
            suppressCooldown: suppression.cooldownRemaining(now: now),
            suppressNote: suppressNote
        )
    }
}
