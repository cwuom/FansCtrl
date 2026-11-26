import Foundation

public struct SmartInputs: Sendable {
    public var cpuLoad: Double
    public var onBattery: Bool
    public var thermal: ThermalLevel
    public var quietFirst: Bool
    public var now: Double

    public init(cpuLoad: Double, onBattery: Bool, thermal: ThermalLevel, quietFirst: Bool, now: Double) {
        self.cpuLoad = cpuLoad
        self.onBattery = onBattery
        self.thermal = thermal
        self.quietFirst = quietFirst
        self.now = now
    }
}

/// 智能档：根据平滑后的负载、供电和热压力，在 图书馆/安静/均衡/性能 之间切换。
/// 升档快、降档慢，避免负载短时波动导致风扇忽快忽慢。
public struct SmartSelector: Sendable {
    public var loadTimeConstant: Double = 20
    public var upgradeDwell: Double = 8
    public var downgradeDwell: Double = 45

    public private(set) var current: FanProfile = .quiet
    public private(set) var reason: String = "初始化"
    public private(set) var loadAverage: Double?
    private var pending: (profile: FanProfile, reason: String, since: Double)?
    private var lastTime: Double?
    private var lastQuietFirst: Bool?

    public init() {}

    private static func rank(_ p: FanProfile) -> Int {
        switch p {
        case .library: return 0
        case .quiet: return 1
        case .balanced: return 2
        case .performance: return 3
        default: return 1
        }
    }

    public static func candidate(load: Double, onBattery: Bool, thermal: ThermalLevel, quietFirst: Bool) -> (FanProfile, String) {
        if quietFirst {
            // 静音优先：始终在静音类档位内选择，过热由曲线安全阀兜底
            return load >= 0.5 ? (.quiet, "静音优先 · 负载较高") : (.library, "静音优先")
        }
        if thermal >= .serious { return (.performance, "系统热压力\(thermal.displayName)") }
        if load >= 0.6 { return onBattery ? (.balanced, "高负载 · 电池供电") : (.performance, "持续高负载") }
        if load <= 0.2 { return onBattery ? (.library, "低负载 · 电池供电") : (.quiet, "低负载") }
        return (.balanced, "中等负载")
    }

    public mutating func step(_ input: SmartInputs) -> FanProfile {
        // 首次采样或用户切换了“静音优先”：属于明确意图，跳过驻留时间立即生效
        let immediate = lastTime == nil || lastQuietFirst != input.quietFirst
        lastQuietFirst = input.quietFirst
        let dt = max(input.now - (lastTime ?? input.now), 0)
        lastTime = input.now
        let load = min(max(input.cpuLoad, 0), 1)
        if let avg = loadAverage {
            let alpha = 1 - exp(-dt / loadTimeConstant)
            loadAverage = avg + alpha * (load - avg)
        } else {
            loadAverage = load
        }

        let (want, why) = Self.candidate(load: loadAverage ?? load, onBattery: input.onBattery,
                                         thermal: input.thermal, quietFirst: input.quietFirst)
        if immediate {
            current = want
            reason = why
            pending = nil
            return current
        }
        if want == current {
            pending = nil
            reason = why
            return current
        }
        // 热压力升档立即生效
        if !input.quietFirst && input.thermal >= .serious {
            current = want
            reason = why
            pending = nil
            return current
        }
        if pending?.profile != want { pending = (want, why, input.now) }
        let dwell = Self.rank(want) > Self.rank(current) ? upgradeDwell : downgradeDwell
        if let p = pending, input.now - p.since >= dwell {
            current = p.profile
            reason = p.reason
            pending = nil
        }
        return current
    }
}
