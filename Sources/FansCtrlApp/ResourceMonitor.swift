import AppKit
import FanCore
import Observation

/// 系统资源与进程监控。只在有界面可见时采样：面板只需轻量的资源数据，
/// 「资源」页可见时才做进程级采样与分析。
@MainActor
@Observable
final class ResourceMonitor {
    enum Detail: Sendable { case light, full }

    private(set) var resources: ResourceSnapshot?
    private(set) var health: [HealthIssue] = []
    private(set) var groups: [ProcessGroup] = []
    var message: String?

    private var lightObservers = 0
    private var fullObservers = 0
    private var loop: Task<Void, Never>?
    private var analyzer = ProcessAnalyzer()
    private static let interval: Duration = .seconds(3)

    var recommendations: [ProcessGroup] { groups.filter(\.isRecommended) }

    func begin(_ detail: Detail) {
        switch detail {
        case .light: lightObservers += 1
        case .full: fullObservers += 1
        }
        startLoopIfNeeded()
    }

    func end(_ detail: Detail) {
        switch detail {
        case .light: lightObservers = max(lightObservers - 1, 0)
        case .full: fullObservers = max(fullObservers - 1, 0)
        }
        if lightObservers + fullObservers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    private func startLoopIfNeeded() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func sampleOnce() async {
        let full = fullObservers > 0
        let apps = full ? Self.appContexts() : []
        let result = await Task.detached(priority: .utility) {
            (SystemResources.sample(), full ? ProcessSampler.sample() : [])
        }.value
        resources = result.0
        health = HealthAdvisor.evaluate(result.0)
        guard full else { return }
        groups = analyzer.update(
            samples: result.1, apps: apps,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            selfPID: getpid(), totalMemory: result.0.memory?.total ?? ProcessInfo.processInfo.physicalMemory,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// 收集运行中 App 的信息。窗口数统计所有普通层级、尺寸像样的窗口：
    /// 只数屏幕上可见的窗口会把其他桌面空间/最小化的窗口漏掉，造成“无窗口”误判。
    private static func appContexts() -> [AppContext] {
        let windows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var counts: [pid_t: Int] = [:]
        for w in windows {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 100 else { continue }
            counts[pid, default: 0] += 1
        }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            let pid = app.processIdentifier
            return AppContext(pid: pid, name: app.localizedName ?? "未知应用", bundleID: app.bundleIdentifier,
                              bundlePath: app.bundleURL?.path, isRegular: app.activationPolicy == .regular,
                              windowCount: counts[pid] ?? 0)
        }
    }

    // MARK: - 操作

    enum EndMode { case graceful, force }

    /// 结束一组进程。执行前重新核对每个 pid 仍属于同一分组，防止 pid 被系统复用后误杀其他进程。
    @discardableResult
    func end(_ group: ProcessGroup, mode: EndMode) -> Bool {
        guard group.protection == nil, let plan = group.plan else { return false }
        switch (plan, mode) {
        case (.quitApp(let pid), _):
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.bundleURL?.path == group.bundlePath else { return false }
            return mode == .force ? app.forceTerminate() : app.terminate()
        case (.terminate(let pids), _):
            var any = false
            for pid in pids where Self.stillBelongs(pid: pid, to: group) {
                if kill(pid, mode == .force ? SIGKILL : SIGTERM) == 0 { any = true }
            }
            return any
        }
    }

    private static func stillBelongs(pid: Int32, to group: ProcessGroup) -> Bool {
        guard let s = ProcessSampler.sample(pid: pid), s.uid == getuid() else { return false }
        let key = ProcessAnalyzer.bundleRoot(of: s.path) ?? "pid:\(pid)"
        return key == group.id
    }

    /// 关闭所有访达窗口（不退出访达）。首次使用时系统会询问是否允许控制“访达”。
    func closeFinderWindows() -> Result<Void, Error> {
        var error: NSDictionary?
        NSAppleScript(source: #"tell application "Finder" to close every window"#)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .failure(CleanupError.automationDenied)
            }
            return .failure(CleanupError.failed(msg))
        }
        return .success(())
    }

    enum CleanupError: Error, CustomStringConvertible {
        case automationDenied
        case failed(String)

        var description: String {
            switch self {
            case .automationDenied: return "没有控制“访达”的权限：请在「系统设置 → 隐私与安全性 → 自动化」中允许 FansCtrl 控制访达"
            case .failed(let m): return "关闭访达窗口失败：\(m)"
            }
        }
    }
}
