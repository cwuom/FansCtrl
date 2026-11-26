import Foundation

/// 由界面层从 NSWorkspace / 窗口列表收集的 App 信息（FanCore 不依赖 AppKit）
public struct AppContext: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var bundlePath: String?
    /// 普通前台 App（有 Dock 图标）
    public var isRegular: Bool
    public var windowCount: Int

    public init(pid: Int32, name: String, bundleID: String?, bundlePath: String?, isRegular: Bool, windowCount: Int) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.isRegular = isRegular
        self.windowCount = windowCount
    }
}

public enum ProcessAnomaly: Hashable, Sendable {
    case sustainedCPU(percent: Double)
    case largeMemory(bytes: UInt64)
    case memoryGrowth(bytes: UInt64, minutes: Int)
    case windowlessHeavyApp(bytes: UInt64)
    case orphanedHelpers

    public var title: String {
        switch self {
        case .sustainedCPU: return "后台持续高 CPU"
        case .largeMemory: return "内存占用过大"
        case .memoryGrowth: return "内存持续增长"
        case .windowlessHeavyApp: return "无窗口仍占内存"
        case .orphanedHelpers: return "主程序已退出"
        }
    }

    public var detail: String {
        switch self {
        case .sustainedCPU(let p):
            return String(format: "近 30 秒平均占用 %.0f%% CPU，且不在前台使用", p)
        case .largeMemory(let b):
            return "占用 \(ByteFormat.string(b)) 内存"
        case .memoryGrowth(let b, let m):
            return "\(m) 分钟内增长 \(ByteFormat.string(b))，可能存在内存泄漏"
        case .windowlessHeavyApp(let b):
            return "已没有打开的窗口，却仍占用 \(ByteFormat.string(b))"
        case .orphanedHelpers:
            return "所属 App 已退出，这些后台进程仍在运行"
        }
    }

    fileprivate var weight: Double {
        switch self {
        case .sustainedCPU, .memoryGrowth: return 3
        case .largeMemory, .windowlessHeavyApp, .orphanedHelpers: return 2
        }
    }
}

public enum ProcessProtection: Equatable, Sendable {
    case system
    case critical
    case selfApp

    public var reason: String {
        switch self {
        case .system: return "系统组件"
        case .critical: return "系统关键进程"
        case .selfApp: return "FansCtrl 自身"
        }
    }
}

public enum TerminationPlan: Equatable, Sendable {
    /// 普通 App：请求正常退出，未保存的文档会提示保存
    case quitApp(pid: Int32)
    /// 无界面的后台进程：发送 SIGTERM
    case terminate(pids: [Int32])
}

/// 按所属 App 归并后的进程组
public struct ProcessGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String?
    public var bundlePath: String?
    public var mainPID: Int32?
    public var pids: [Int32]
    /// 平滑后的 CPU 占用（100% = 一个核心）
    public var cpuPercent: Double
    public var footprint: UInt64
    public var isApp: Bool
    public var isFrontmost: Bool
    public var windowCount: Int
    public var protection: ProcessProtection?
    public var anomalies: [ProcessAnomaly]
    public var score: Double

    /// 有异常、不受保护、且不是用户正在用的前台 App，才建议结束
    public var isRecommended: Bool { !anomalies.isEmpty && protection == nil && !isFrontmost }

    public var plan: TerminationPlan? {
        guard protection == nil else { return nil }
        if let main = mainPID, isApp { return .quitApp(pid: main) }
        return .terminate(pids: pids)
    }
}

public struct ProcessAnalyzerConfig: Sendable {
    public var cpuTimeConstant: Double = 30
    public var sustainedCPUPercent: Double = 80
    public var minObservation: Double = 20
    public var largeMemoryMin: UInt64 = 2 * 1_073_741_824
    public var largeMemoryFraction: Double = 0.15
    public var growthWindow: Double = 600
    public var growthMinObservation: Double = 300
    public var growthMinBytes: UInt64 = 512 * 1_048_576
    public var growthMinRatio: Double = 0.5
    public var windowlessMinBytes: UInt64 = 500 * 1_048_576
    public var orphanMinBytes: UInt64 = 300 * 1_048_576
    public var orphanMinCPU: Double = 10

    public init() {}
}

/// 智能进程分析：归并辅助进程、识别异常、给出结束建议。纯逻辑，可测试。
public struct ProcessAnalyzer: Sendable {
    public var config: ProcessAnalyzerConfig

    private struct CPUMark: Sendable { var start: TimeInterval; var cpu: UInt64; var at: Double }
    private var cpuMarks: [Int32: CPUMark] = [:]
    private var cpuEMA: [String: Double] = [:]
    private var lastUpdate: Double?
    private var firstSeen: [String: Double] = [:]
    private var memHistory: [String: [(t: Double, bytes: UInt64)]] = [:]

    public static let criticalNames: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager",
        "loginwindow", "Spotlight", "WindowServer",
    ]
    private static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/"]

    public init(config: ProcessAnalyzerConfig = ProcessAnalyzerConfig()) { self.config = config }

    /// 取路径中最外层的 .app 包，辅助进程据此归入所属 App
    public static func bundleRoot(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public mutating func update(samples: [ProcessSample], apps: [AppContext], frontmostPID: Int32?,
                                selfPID: Int32, totalMemory: UInt64, now: Double) -> [ProcessGroup] {
        let dt = lastUpdate.map { now - $0 } ?? 0
        lastUpdate = now

        // 1. 每个进程的瞬时 CPU（pid 复用时以启动时间区分）
        var instant: [Int32: Double] = [:]
        var marks: [Int32: CPUMark] = [:]
        for s in samples {
            if let prev = cpuMarks[s.pid], prev.start == s.startTime, now > prev.at, s.cpuTimeNs >= prev.cpu {
                instant[s.pid] = Double(s.cpuTimeNs - prev.cpu) / ((now - prev.at) * 1e9) * 100
            }
            marks[s.pid] = CPUMark(start: s.startTime, cpu: s.cpuTimeNs, at: now)
        }
        cpuMarks = marks

        // 2. 归并
        let appsByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let appsByBundle = Dictionary(apps.compactMap { a in a.bundlePath.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var buckets: [String: [ProcessSample]] = [:]
        for s in samples {
            let key = Self.bundleRoot(of: s.path) ?? appsByPID[s.pid]?.bundlePath ?? "pid:\(s.pid)"
            buckets[key, default: []].append(s)
        }

        let largeThreshold = max(config.largeMemoryMin, UInt64(Double(totalMemory) * config.largeMemoryFraction))
        let alpha = dt > 0 ? 1 - exp(-dt / config.cpuTimeConstant) : 1
        var groups: [ProcessGroup] = []
        var seen = Set<String>()

        for (key, procs) in buckets {
            seen.insert(key)
            let app = appsByBundle[key] ?? procs.lazy.compactMap { appsByPID[$0.pid] }.first
            let pids = procs.map(\.pid).sorted()
            let footprint = procs.reduce(UInt64(0)) { $0 + $1.footprint }
            let cpuNow = procs.reduce(0.0) { $0 + (instant[$1.pid] ?? 0) }
            let ema = cpuEMA[key].map { $0 + alpha * (cpuNow - $0) } ?? cpuNow
            cpuEMA[key] = ema
            let first = firstSeen[key] ?? now
            firstSeen[key] = first
            var history = (memHistory[key] ?? []).filter { now - $0.t <= config.growthWindow }
            history.append((now, footprint))
            memHistory[key] = history

            let fallbackName = key.hasPrefix("pid:")
                ? (procs.first?.name ?? key)
                : ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = app?.name ?? fallbackName
            let isApp = app?.isRegular ?? false
            let frontmost = frontmostPID.map { pids.contains($0) || app?.pid == $0 } ?? false
            let path = procs.first?.path ?? ""

            var protection: ProcessProtection?
            if pids.contains(selfPID) {
                protection = .selfApp
            } else if Self.criticalNames.contains(name) || procs.contains(where: { Self.criticalNames.contains($0.name) }) {
                protection = .critical
            } else if Self.systemPrefixes.contains(where: { path.hasPrefix($0) }) {
                protection = .system
            }

            var anomalies: [ProcessAnomaly] = []
            if !frontmost, now - first >= config.minObservation, ema >= config.sustainedCPUPercent {
                anomalies.append(.sustainedCPU(percent: ema))
            }
            if let oldest = history.first, now - oldest.t >= config.growthMinObservation,
               let minBytes = history.map(\.bytes).min(), footprint > minBytes {
                let growth = footprint - minBytes
                if growth >= max(config.growthMinBytes, UInt64(Double(minBytes) * config.growthMinRatio)) {
                    anomalies.append(.memoryGrowth(bytes: growth, minutes: Int((now - oldest.t) / 60)))
                }
            }
            if footprint >= largeThreshold {
                anomalies.append(.largeMemory(bytes: footprint))
            } else if isApp, !frontmost, (app?.windowCount ?? 1) == 0, footprint >= config.windowlessMinBytes {
                anomalies.append(.windowlessHeavyApp(bytes: footprint))
            }
            if app == nil, !key.hasPrefix("pid:"), procs.allSatisfy({ $0.ppid == 1 }),
               footprint >= config.orphanMinBytes || ema >= config.orphanMinCPU {
                anomalies.append(.orphanedHelpers)
            }

            let score = anomalies.reduce(0) { $0 + $1.weight }
                + min(ema / 100, 4) * 2
                + Double(footprint) / Double(max(totalMemory, 1)) * 10

            groups.append(ProcessGroup(
                id: key, name: name, bundleID: app?.bundleID, bundlePath: key.hasPrefix("pid:") ? nil : key,
                mainPID: app?.pid, pids: pids, cpuPercent: ema, footprint: footprint, isApp: isApp,
                isFrontmost: frontmost, windowCount: app?.windowCount ?? 0, protection: protection,
                anomalies: anomalies, score: score
            ))
        }

        // 已消失的分组不再保留历史，防止长期运行时内存增长
        for key in Array(cpuEMA.keys) where !seen.contains(key) {
            cpuEMA[key] = nil
            firstSeen[key] = nil
            memHistory[key] = nil
        }
        return groups.sorted { $0.score > $1.score }
    }
}

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
