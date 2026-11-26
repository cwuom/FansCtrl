import Foundation

public enum FanProfile: String, Codable, CaseIterable, Sendable {
    case system
    case library
    case quiet
    case balanced
    case performance
    case max
    case smart

    public var displayName: String {
        switch self {
        case .system: return "系统默认"
        case .library: return "图书馆"
        case .quiet: return "安静"
        case .balanced: return "均衡"
        case .performance: return "性能"
        case .max: return "全速"
        case .smart: return "智能"
        }
    }

    public var summary: String {
        switch self {
        case .system: return "完全交给 macOS 控制"
        case .library: return "转速封顶在近乎无声的区间，过热时自动放开"
        case .quiet: return "低噪优先，留出更多散热余量"
        case .balanced: return "比系统更早介入，噪音与温度折中"
        case .performance: return "提前拉高转速，减少降频，适合渲染/编译"
        case .max: return "风扇满速，临时快速降温"
        case .smart: return "根据负载、电源和温度自动切换档位"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "fan"
        case .library: return "books.vertical"
        case .quiet: return "moon"
        case .balanced: return "dial.medium"
        case .performance: return "bolt"
        case .max: return "tornado"
        case .smart: return "wand.and.stars"
        }
    }
}

/// 档位的控制策略。转速统一用“最小到最大转速之间的比例”表达，同一套参数可适配不同 Mac 的风扇。
public enum ProfilePolicy: Equatable, Sendable {
    /// 完全交给系统
    case system
    /// 静音封顶：平时交给系统，系统想转得比封顶更快时接管并压在封顶值。保证永远不比系统默认更吵。
    case cap(ceiling: Double)
    /// 按曲线主动调速（比系统更早、更积极地散热）
    case curve(FanCurve)
    /// 满速
    case full

    public static func forProfile(_ p: FanProfile) -> ProfilePolicy {
        switch p {
        case .system, .smart:
            return .system
        case .library:
            // M5 14" 上 0.12 ≈ 2830 RPM：接近风扇最低运转转速，安静环境中基本听不到
            return .cap(ceiling: 0.12)
        case .quiet:
            return .cap(ceiling: 0.30)
        case .balanced:
            return .curve(FanCurve(handBackBelow: 60, points: [(60, 0), (80, 0.15), (90, 0.35), (100, 0.7), (105, 1)]))
        case .performance:
            return .curve(FanCurve(handBackBelow: 50, points: [(50, 0.1), (70, 0.4), (85, 0.8), (95, 1)]))
        case .max:
            return .full
        }
    }
}

public struct FanCurve: Equatable, Sendable {
    /// 温度低于该值时交还系统（Apple Silicon 系统在低温下通常停转，比任何手动转速都安静）
    public let handBackBelow: Double?
    /// (温度 °C, 转速比例 0...1)，按温度递增
    public let points: [(Double, Double)]

    public init(handBackBelow: Double?, points: [(Double, Double)]) {
        precondition(!points.isEmpty, "curve needs points")
        self.handBackBelow = handBackBelow
        self.points = points
    }

    public static func == (a: FanCurve, b: FanCurve) -> Bool {
        a.handBackBelow == b.handBackBelow && a.points.count == b.points.count
            && zip(a.points, b.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// 分段线性插值，结果夹到 [0, 1]
    public func fraction(at temp: Double) -> Double {
        var raw = points[0].1
        if let last = points.last, temp >= last.0 {
            raw = last.1
        } else if temp > points[0].0 {
            for (a, b) in zip(points, points.dropFirst()) where temp >= a.0 && temp <= b.0 {
                raw = a.1 + (b.1 - a.1) * (temp - a.0) / (b.0 - a.0)
                break
            }
        }
        return min(max(raw, 0), 1)
    }
}
