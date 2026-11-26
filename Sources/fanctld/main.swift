import Darwin
import FanCore
import Foundation

// 用法：fanctld [--dry-run] [--socket PATH] [--config PATH]
// --dry-run 只读不写 SMC，可用普通用户身份调试控制逻辑。
//
// 入口逻辑放在非隔离的类型里：main.swift 顶层代码默认隶属 MainActor，
// 而 dispatchMain() 之后主队列的任务可能跑在其他线程，会触发隔离检查。
enum DaemonMain {
    nonisolated(unsafe) static var keepAlive: [AnyObject] = []

    static func run() -> Never {
        var dryRun = false
        var socketPath = IPC.defaultSocketPath
        var configPath = DaemonConfig.defaultPath
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--dry-run": dryRun = true
            case "--socket": socketPath = args.next() ?? socketPath
            case "--config": configPath = args.next() ?? configPath
            default: die("未知参数: \(a)", code: 64)
            }
        }
        if !dryRun && geteuid() != 0 { die("fanctld 需要 root 权限写入 SMC；调试请加 --dry-run", code: 77) }

        let daemon = Daemon(dryRun: dryRun, configPath: configPath)
        let ownerUID = getuid()
        let allowOwner = dryRun
        let server = IPCServer(
            path: socketPath,
            authorize: { uid in
                if uid == 0 { return true }
                if allowOwner && uid == ownerUID { return true }
                return uid == IPCServer.consoleUID()
            },
            handler: { daemon.handle($0) }
        )
        do {
            try server.start()
        } catch {
            // IPC 起不来就不运行：没有界面能看到状态时，风扇保持系统控制更安全
            daemon.shutdown()
            die("IPC 启动失败: \(error)", code: 1)
        }

        let power = PowerEvents(onSleep: { daemon.willSleep() }, onWake: { daemon.didWake() })
        if !power.start(queue: DispatchQueue(label: "com.fansctrl.power")) {
            log.error("power notifications unavailable")
        }

        let signalQueue = DispatchQueue(label: "com.fansctrl.signal")
        var sources: [AnyObject] = [daemon, server, power]
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler {
                daemon.shutdown()
                server.stop()
                exit(0)
            }
            src.resume()
            sources.append(src)
        }
        keepAlive = sources

        daemon.start()
        dispatchMain()
    }

    static func die(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}

DaemonMain.run()
