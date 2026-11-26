import Foundation

public enum IPC {
    public static let defaultSocketPath = "/var/run/com.fansctrl.daemon.sock"
    public static let maxMessageBytes = 16 * 1024
    /// 每次新增命令或状态字段都要递增，App 据此判断后台服务是否需要更新。
    /// 1：初版；2：强力压制（suppress 命令与 suppress* 状态字段）
    public static let protocolVersion = 2

    /// 允许用环境变量指向开发态（非 root dry-run）守护进程。
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["FANSCTRL_SOCKET"] ?? defaultSocketPath
    }
}

/// 客户端只能发这几种命令。守护进程不暴露任意 SMC 读写，这是安全边界。
public enum IPCCommand: Equatable, Sendable {
    case status
    case setProfile(FanProfile)
    case setQuietFirst(Bool)
    /// true 开启强力压制（固定 60 秒），false 提前结束
    case setSuppress(Bool)

    private struct Wire: Codable {
        var cmd: String
        var profile: String?
        var value: Bool?
    }

    public func encoded() throws -> Data {
        let wire: Wire
        switch self {
        case .status: wire = Wire(cmd: "status")
        case .setProfile(let p): wire = Wire(cmd: "setProfile", profile: p.rawValue)
        case .setQuietFirst(let v): wire = Wire(cmd: "setQuietFirst", value: v)
        case .setSuppress(let v): wire = Wire(cmd: "suppress", value: v)
        }
        return try JSONEncoder().encode(wire)
    }

    public static func parse(_ data: Data) throws -> IPCCommand {
        guard data.count <= IPC.maxMessageBytes else { throw IPCError.invalidRequest("请求过大") }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch { throw IPCError.invalidRequest("JSON 格式错误") }
        switch wire.cmd {
        case "status":
            return .status
        case "setProfile":
            guard let raw = wire.profile, let p = FanProfile(rawValue: raw) else { throw IPCError.invalidRequest("未知档位") }
            return .setProfile(p)
        case "setQuietFirst":
            guard let v = wire.value else { throw IPCError.invalidRequest("缺少 value") }
            return .setQuietFirst(v)
        case "suppress":
            guard let v = wire.value else { throw IPCError.invalidRequest("缺少 value") }
            return .setSuppress(v)
        default:
            throw IPCError.invalidRequest("未知命令")
        }
    }
}

public enum IPCError: Error, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case notRunning
    case permissionDenied
    case io(String)

    public var description: String {
        switch self {
        case .invalidRequest(let m): return "请求无效：\(m)"
        case .notRunning: return "后台服务未运行"
        case .permissionDenied: return "无权访问后台服务"
        case .io(let m): return "通信失败：\(m)"
        }
    }
}

public struct FanStatus: Codable, Equatable, Sendable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minRPM: Double
    public var maxRPM: Double
    public var manual: Bool?
    /// 守护进程下发（dry-run 时为计划下发）的转速；nil 表示交给系统
    public var plannedRPM: Double?

    public init(index: Int, actualRPM: Double?, targetRPM: Double?, minRPM: Double, maxRPM: Double, manual: Bool?, plannedRPM: Double?) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.manual = manual
        self.plannedRPM = plannedRPM
    }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var protocolVersion: Int = IPC.protocolVersion

    /// 后台服务版本；旧版服务不发送该字段
    public var daemonVersion: String? = BuildInfo.serviceVersion

    /// 后台服务比 App 旧：部分功能（如强力压制）不可用，需要重新安装服务
    public var isOutdated: Bool { protocolVersion < IPC.protocolVersion }

    /// 后台服务与 App 版本不一致：即使协议兼容，服务端的修复也要重新安装才生效
    public var isVersionMismatch: Bool { isOutdated || daemonVersion != BuildInfo.serviceVersion }
    public var model: String
    public var selectedProfile: FanProfile
    public var activeProfile: FanProfile
    public var smartReason: String?
    public var quietFirst: Bool
    public var state: ControlState
    public var cpuTemp: Double?
    public var gpuTemp: Double?
    public var controlTemp: Double?
    public var cpuLoad: Double?
    public var onBattery: Bool
    public var thermal: ThermalLevel
    public var fans: [FanStatus]
    public var controlSupported: Bool
    public var dryRun: Bool
    public var lastError: String?
    /// 强力压制剩余秒数；未在压制时为 nil
    public var suppressRemaining: Double?
    /// 强力压制冷却剩余秒数
    public var suppressCooldown: Double?
    /// 强力压制被安全机制提前结束的原因
    public var suppressNote: String?

    public init(
        model: String,
        selectedProfile: FanProfile,
        activeProfile: FanProfile,
        smartReason: String?,
        quietFirst: Bool,
        state: ControlState,
        cpuTemp: Double?,
        gpuTemp: Double?,
        controlTemp: Double?,
        cpuLoad: Double?,
        onBattery: Bool,
        thermal: ThermalLevel,
        fans: [FanStatus],
        controlSupported: Bool,
        dryRun: Bool,
        lastError: String?,
        suppressRemaining: Double? = nil,
        suppressCooldown: Double? = nil,
        suppressNote: String? = nil
    ) {
        self.model = model
        self.selectedProfile = selectedProfile
        self.activeProfile = activeProfile
        self.smartReason = smartReason
        self.quietFirst = quietFirst
        self.state = state
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.controlTemp = controlTemp
        self.cpuLoad = cpuLoad
        self.onBattery = onBattery
        self.thermal = thermal
        self.fans = fans
        self.controlSupported = controlSupported
        self.dryRun = dryRun
        self.lastError = lastError
        self.suppressRemaining = suppressRemaining
        self.suppressCooldown = suppressCooldown
        self.suppressNote = suppressNote
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: StatusSnapshot?

    public init(ok: Bool, error: String? = nil, status: StatusSnapshot? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
    }
}
