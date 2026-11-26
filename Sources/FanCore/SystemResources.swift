import Darwin
import Foundation

public enum MemoryPressure: Int, Codable, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "严重"
        }
    }
}

public struct MemoryStats: Equatable, Sendable {
    public var total: UInt64
    /// 与活动监视器“已使用内存”一致：App 内存 + 联动内存 + 被压缩内存
    public var used: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public var available: UInt64 { total > used ? total - used : 0 }

    public init(total: UInt64, used: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64,
                swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) {
        self.total = total
        self.used = used
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    /// 按活动监视器的口径由页计数换算。纯函数，便于测试。
    public static func from(pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                            compressorPages: UInt64, total: UInt64, swapUsed: UInt64, swapTotal: UInt64,
                            pressure: MemoryPressure) -> MemoryStats {
        let app = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressorPages * pageSize
        return MemoryStats(total: total, used: min(app + wired + compressed, total), appMemory: app, wired: wired,
                           compressed: compressed, swapUsed: swapUsed, swapTotal: swapTotal, pressure: pressure)
    }
}

public struct DiskStats: Equatable, Sendable {
    public var total: UInt64
    /// 与访达显示的“可用”一致，包含可清除空间
    public var available: UInt64

    public init(total: UInt64, available: UInt64) {
        self.total = total
        self.available = available
    }

    public var availableFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }
}

public struct ResourceSnapshot: Equatable, Sendable {
    public var memory: MemoryStats?
    public var disk: DiskStats?
    /// 自开机起的墙钟时长（含睡眠）
    public var uptime: TimeInterval?

    public init(memory: MemoryStats?, disk: DiskStats?, uptime: TimeInterval?) {
        self.memory = memory
        self.disk = disk
        self.uptime = uptime
    }
}

/// 低开销的系统资源采样，全部为用户态可读的接口，不需要 root。
public enum SystemResources {
    public static func sample() -> ResourceSnapshot {
        ResourceSnapshot(memory: memory(), disk: disk(), uptime: uptime())
    }

    public static func memory() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
            ? MemoryPressure(rawValue: Int(level)) ?? .normal : .normal

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        return MemoryStats.from(
            pageSize: UInt64(pageSize),
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            total: ProcessInfo.processInfo.physicalMemory,
            swapUsed: hasSwap ? swap.xsu_used : 0,
            swapTotal: hasSwap ? swap.xsu_total : 0,
            pressure: pressure
        )
    }

    public static func disk(path: String = "/") -> DiskStats? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskStats(total: UInt64(total), available: UInt64(max(available, 0)))
    }

    public static func uptime(now: Date = Date()) -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        return now.timeIntervalSince(bootDate)
    }
}

// MARK: - 健康评估

public struct HealthIssue: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case info = 0, warning, critical
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var severity: Severity
    public var title: String
    public var advice: String
}

/// 针对“长时间不关机”的健康检查，阈值相对于本机内存/磁盘大小，适配不同配置的 Mac。
public enum HealthAdvisor {
    public static func evaluate(_ r: ResourceSnapshot) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let gb = 1_073_741_824.0

        if let m = r.memory {
            switch m.pressure {
            case .critical:
                issues.append(HealthIssue(id: "pressure", severity: .critical, title: "内存压力严重",
                                          advice: "系统正在大量压缩和交换内存，请先退出下方建议处理的大内存应用"))
            case .warning:
                issues.append(HealthIssue(id: "pressure", severity: .warning, title: "内存压力偏高",
                                          advice: "退出暂时不用的应用可以明显改善流畅度"))
            case .normal:
                break
            }
            let swapRatio = Double(m.swapUsed) / Double(max(m.total, 1))
            if swapRatio >= 0.5 {
                issues.append(HealthIssue(id: "swap", severity: .critical,
                                          title: String(format: "交换空间已用 %.1f GB", Double(m.swapUsed) / gb),
                                          advice: "长期大量交换会拖慢系统并加速磨损磁盘，建议退出大内存应用或重启"))
            } else if swapRatio >= 0.25 {
                issues.append(HealthIssue(id: "swap", severity: .warning,
                                          title: String(format: "交换空间已用 %.1f GB", Double(m.swapUsed) / gb),
                                          advice: "退出闲置的大内存应用后，交换空间会逐步回收"))
            }
        }

        if let d = r.disk {
            let freeGB = Double(d.available) / gb
            if d.availableFraction < 0.05 || freeGB < 10 {
                issues.append(HealthIssue(id: "disk", severity: .critical,
                                          title: String(format: "磁盘仅剩 %.0f GB", freeGB),
                                          advice: "空间不足会导致交换失败、应用卡死，请尽快清理大文件"))
            } else if d.availableFraction < 0.10 || freeGB < 20 {
                issues.append(HealthIssue(id: "disk", severity: .warning,
                                          title: String(format: "磁盘剩余 %.0f GB", freeGB),
                                          advice: "建议保留至少 10% 的可用空间，供交换文件和系统更新使用"))
            }
        }

        if let up = r.uptime {
            let days = up / 86_400
            if days >= 21 {
                issues.append(HealthIssue(id: "uptime", severity: .warning, title: "已连续运行 \(Int(days)) 天",
                                          advice: "长期不重启会累积内存碎片和后台残留，找个空闲时间重启一次"))
            } else if days >= 7 {
                issues.append(HealthIssue(id: "uptime", severity: .info, title: "已连续运行 \(Int(days)) 天",
                                          advice: "可以先用“一键整理”回收资源，必要时再重启"))
            }
        }
        return issues.sorted { $0.severity > $1.severity }
    }
}
