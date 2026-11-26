import Darwin
import Foundation
import IOKit.ps

/// 低开销的系统信号采样：CPU 负载用 host_statistics 计数差分，无需遍历进程。
public final class CPULoadSampler {
    private var previous: host_cpu_load_info?

    public init() {}

    /// 返回自上次调用以来的整体 CPU 使用率 0...1；首次调用返回 nil。
    public func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let prev = previous else { return nil }
        func d(_ i: Int32) -> Double {
            let now = tupleValue(info.cpu_ticks, i)
            let old = tupleValue(prev.cpu_ticks, i)
            return Double(now &- old)
        }
        let user = d(CPU_STATE_USER), sys = d(CPU_STATE_SYSTEM), nice = d(CPU_STATE_NICE), idle = d(CPU_STATE_IDLE)
        let total = user + sys + nice + idle
        return total > 0 ? (user + sys + nice) / total : nil
    }

    private func tupleValue(_ t: (natural_t, natural_t, natural_t, natural_t), _ i: Int32) -> natural_t {
        switch i {
        case 0: return t.0
        case 1: return t.1
        case 2: return t.2
        default: return t.3
        }
    }
}

public enum SystemSignals {
    public static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    public static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    public static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "Unknown" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
