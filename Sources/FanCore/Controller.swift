import Foundation

public enum ThermalLevel: Int, Codable, Sendable, Comparable {
    case nominal = 0, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "略高"
        case .serious: return "较高"
        case .critical: return "危急"
        }
    }
}

public enum ControlState: String, Codable, Sendable {
    /// 风扇由系统控制（选择了系统默认，或温度低于接管阈值）
    case system
    /// 按档位曲线手动控制
    case manual
    /// 静音档正在把系统想要的转速压在封顶值
    case capped
    /// 强力压制：临时压到最低转速
    case suppressed
    /// 静音类档位过热，安全阀已放开交还系统
    case released
    /// 温度达到紧急阈值，满速
    case emergency
    /// 读不到可信温度，交还系统
    case sensorFault
    /// 睡眠/唤醒过渡期
    case paused
    /// 本机不支持或固件拒绝手动控制
    case unsupported

    public var displayName: String {
        switch self {
        case .system: return "系统控制"
        case .manual: return "按档位调速"
        case .capped: return "静音封顶中"
        case .suppressed: return "强力压制中"
        case .released: return "过热保护：已交还系统"
        case .emergency: return "紧急降温：满速"
        case .sensorFault: return "传感器异常：已交还系统"
        case .paused: return "暂停（睡眠/唤醒）"
        case .unsupported: return "本机不支持手动控制"
        }
    }
}

public struct ControlDecision: Equatable, Sendable {
    public let state: ControlState
    /// nil 表示交还系统自动控制
    public let targets: [Int: Double]?

    public static func automatic(_ s: ControlState) -> ControlDecision { ControlDecision(state: s, targets: nil) }
}

/// 控制器每次采样看到的单个风扇。
public struct FanSample: Equatable, Sendable {
    public let spec: FanSpec
    public let actualRPM: Double?
    /// 风扇处于系统自动模式时 SMC 里的目标转速，即系统“想要”的转速；手动模式下为 nil
    public let systemTargetRPM: Double?

    public init(spec: FanSpec, actualRPM: Double?, systemTargetRPM: Double?) {
        self.spec = spec
        self.actualRPM = actualRPM
        self.systemTargetRPM = systemTargetRPM
    }
}

public struct ControllerTuning: Sendable {
    /// 超过即满速（用原始温度判断，不等平滑）
    public var emergencyTemp: Double
    public var emergencyRecover: Double
    /// 静音封顶档的安全阀：平滑温度超过此值或热压力达到 serious，交还系统全力散热
    public var capReleaseTemp: Double
    public var capReleaseHysteresis: Double = 6
    /// 封顶后温度降到此值以下才交还系统。系统自己的曲线有滞后，过早交还会被系统猛地拉高、
    /// 随即又被封顶，形成忽高忽低的噪音
    public var capHandBackBelow: Double
    /// 升速是最容易被听到的变化，非紧急情况一律缓慢升速
    public var rampUpPerSecond: Double = 300
    /// 降速慢于升速：转速来回抖动比稳定的低速更容易被注意到
    public var rampDownPerSecond: Double = 250
    public var deadbandRPM: Double = 80
    public var handBackHysteresis: Double = 4
    public var riseAlpha: Double = 0.6
    public var fallAlpha: Double = 0.2

    /// Apple Silicon 的 SoC 在 100°C 左右运行是系统设计内的常态，阈值相应更高
    public static let appleSilicon = ControllerTuning(emergencyTemp: 108, emergencyRecover: 100, capReleaseTemp: 103,
                                                      capHandBackBelow: 60)
    /// Intel 处理器在 100°C 左右开始硬件降频
    public static let intel = ControllerTuning(emergencyTemp: 99, emergencyRecover: 90, capReleaseTemp: 95,
                                               capHandBackBelow: 55)

    public init(emergencyTemp: Double, emergencyRecover: Double, capReleaseTemp: Double, capHandBackBelow: Double) {
        self.emergencyTemp = emergencyTemp
        self.emergencyRecover = emergencyRecover
        self.capReleaseTemp = capReleaseTemp
        self.capHandBackBelow = capHandBackBelow
    }
}

/// 纯逻辑控制器：输入温度和风扇采样，输出“交还系统”或各风扇目标转速。不触碰硬件，便于测试。
public struct FanController: Sendable {
    public let tuning: ControllerTuning
    public private(set) var smoothedTemp: Double?
    private var engaged = false
    private var capping = false
    private var capTargets: [Int: Double] = [:]
    private var releasedLatch = false
    private var emergencyLatch = false
    private var last: [Int: Double] = [:]
    private var lastTime: Double?

    public init(tuning: ControllerTuning = .appleSilicon) { self.tuning = tuning }

    public mutating func reset() {
        let t = tuning
        self = FanController(tuning: t)
    }

    /// 切换档位：只清掉与旧档位相关的判定状态，保留当前输出转速与平滑温度，
    /// 新档位从当前转速平滑过渡，而不是从头开始造成突变。紧急状态同样保留。
    public mutating func profileChanged() {
        releasedLatch = false
        capping = false
        capTargets = [:]
    }

    private mutating func disengage() {
        engaged = false
        capping = false
        capTargets = [:]
        last = [:]
    }

    /// - Parameter suppress: 强力压制期间为 true。紧急满速与过热放开仍然优先于压制。
    public mutating func step(profile: FanProfile, temp: Double?, thermal: ThermalLevel,
                              fans: [FanSample], now: Double, suppress: Bool = false) -> ControlDecision {
        let policy = ProfilePolicy.forProfile(profile)
        let dt = min(max(now - (lastTime ?? (now - 2)), 0.5), 10)
        lastTime = now

        guard (policy != .system || suppress), !fans.isEmpty else {
            reset()
            return .automatic(.system)
        }
        guard let raw = temp else {
            reset()
            return .automatic(.sensorFault)
        }
        let s = smoothedTemp.map { $0 + (raw > $0 ? tuning.riseAlpha : tuning.fallAlpha) * (raw - $0) } ?? raw
        smoothedTemp = s

        if raw >= tuning.emergencyTemp || thermal == .critical {
            emergencyLatch = true
        } else if emergencyLatch && raw < tuning.emergencyRecover {
            emergencyLatch = false
        }
        if emergencyLatch {
            disengage()
            engaged = true
            last = Dictionary(uniqueKeysWithValues: fans.map { ($0.spec.index, $0.spec.maxRPM) })
            return ControlDecision(state: .emergency, targets: last)
        }

        if suppress {
            // 压制期间温度仍过高：立即放弃压制，交还系统全力散热
            if s >= tuning.capReleaseTemp {
                disengage()
                return .automatic(.released)
            }
            disengage()
            engaged = true
            // 不走斜率，立即压到最低转速，这正是“瞬间降噪”
            last = Dictionary(uniqueKeysWithValues: fans.map { ($0.spec.index, $0.spec.minRPM) })
            return ControlDecision(state: .suppressed, targets: last)
        }

        switch policy {
        case .system:
            return .automatic(.system)

        case .full:
            capping = false
            engaged = true
            let desired = Dictionary(uniqueKeysWithValues: fans.map { ($0.spec.index, $0.spec.maxRPM) })
            return ControlDecision(state: .manual, targets: ramp(fans, desired: desired, dt: dt))

        case .cap(let ceiling):
            if s >= tuning.capReleaseTemp || thermal >= .serious {
                releasedLatch = true
            } else if releasedLatch && s < tuning.capReleaseTemp - tuning.capReleaseHysteresis && thermal < .serious {
                releasedLatch = false
            }
            if releasedLatch {
                disengage()
                return .automatic(.released)
            }
            if capping && s < tuning.capHandBackBelow {
                disengage()
                return .automatic(.system)
            }
            if !capping && engaged && !last.isEmpty {
                // 已在手动控制（从均衡/性能/全速切过来）：直接从当前转速平滑压到封顶，
                // 不经过“交还系统”，避免被系统突然拉高
                capping = true
                capTargets = Dictionary(uniqueKeysWithValues: fans.map { f in
                    (f.spec.index, min(last[f.spec.index] ?? f.spec.minRPM, ceilingRPM(f.spec, ceiling)))
                })
            }
            if !capping {
                let over = fans.contains { f in
                    guard let want = f.systemTargetRPM else { return false }
                    return want > ceilingRPM(f.spec, ceiling) + tuning.deadbandRPM
                }
                guard over else {
                    disengage()
                    return .automatic(.system)
                }
                capping = true
                engaged = true
                // 系统本来就转得比封顶慢的风扇保持系统当时的转速，不被“抬高”到封顶
                capTargets = Dictionary(uniqueKeysWithValues: fans.map { f in
                    let c = ceilingRPM(f.spec, ceiling)
                    return (f.spec.index, min(c, max(f.systemTargetRPM ?? f.spec.minRPM, f.spec.minRPM)))
                })
            }
            let targets = ramp(fans, desired: capTargets, dt: dt)
            return ControlDecision(state: .capped, targets: targets)

        case .curve(let curve):
            capping = false
            if let hb = curve.handBackBelow {
                if engaged && s < hb - tuning.handBackHysteresis {
                    disengage()
                } else if !engaged && s >= hb {
                    engaged = true
                }
                if !engaged { return .automatic(.system) }
            } else {
                engaged = true
            }
            let fraction = curve.fraction(at: s)
            let desired = Dictionary(uniqueKeysWithValues: fans.map { f in
                (f.spec.index, f.spec.minRPM + fraction * (f.spec.maxRPM - f.spec.minRPM))
            })
            return ControlDecision(state: .manual, targets: ramp(fans, desired: desired, dt: dt))
        }
    }

    private func ceilingRPM(_ spec: FanSpec, _ ceiling: Double) -> Double {
        spec.minRPM + ceiling * (spec.maxRPM - spec.minRPM)
    }

    /// 按升降斜率逼近目标；死区内不改写，减少 SMC 写入次数。
    private mutating func ramp(_ fans: [FanSample], desired: [Int: Double], dt: Double) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for f in fans {
            let spec = f.spec
            let want = min(max(desired[spec.index] ?? spec.minRPM, spec.minRPM), spec.maxRPM)
            let base = min(max(last[spec.index] ?? f.actualRPM ?? spec.minRPM, spec.minRPM), spec.maxRPM)
            let delta = want - base
            let next: Double
            if abs(delta) >= tuning.deadbandRPM {
                next = base + min(max(delta, -tuning.rampDownPerSecond * dt), tuning.rampUpPerSecond * dt)
            } else {
                // 死区内不改写以减少 SMC 写入；但目标是最低/最高转速时要精确落到位（全速就该是满速）
                next = (want == spec.maxRPM || want == spec.minRPM) ? want : base
            }
            out[spec.index] = next.rounded()
        }
        last = out
        return out
    }
}
