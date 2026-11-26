import Darwin
import Foundation

public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: uid_t
    public var name: String
    public var path: String
    /// 累计 CPU 时间（纳秒，用户态 + 内核态）
    public var cpuTimeNs: UInt64
    /// 物理内存占用（与活动监视器“内存”列一致）
    public var footprint: UInt64
    /// 进程启动时间，用于识别 pid 复用
    public var startTime: TimeInterval

    public init(pid: Int32, ppid: Int32, uid: uid_t, name: String, path: String, cpuTimeNs: UInt64,
                footprint: UInt64, startTime: TimeInterval) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.cpuTimeNs = cpuTimeNs
        self.footprint = footprint
        self.startTime = startTime
    }
}

/// 基于 libproc 的进程采样。只采集指定用户的进程：其他用户（含 root）的进程既读不全，用户也无权结束。
public enum ProcessSampler {
    /// rusage 的 CPU 时间在 Apple Silicon 上是 mach 时间单位，需按 timebase 换算成纳秒
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    public static func sample(uid: uid_t = getuid()) -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard n > 0 else { return [] }

        var result: [ProcessSample] = []
        result.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            guard let s = sample(pid: pid), s.uid == uid else { continue }
            result.append(s)
        }
        return result
    }

    public static func sample(pid: Int32) -> ProcessSample? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }

        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { return nil }

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? decode(pathBuf) : ""

        let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let mach = usage.ri_user_time &+ usage.ri_system_time
        return ProcessSample(
            pid: pid,
            ppid: Int32(bsd.pbi_ppid),
            uid: bsd.pbi_uid,
            name: name.isEmpty ? (path as NSString).lastPathComponent : name,
            path: path,
            cpuTimeNs: mach / timebase.denom * timebase.numer,
            footprint: usage.ri_phys_footprint,
            startTime: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
        )
    }

    private static func decode(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
