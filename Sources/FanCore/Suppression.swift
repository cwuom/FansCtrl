import Foundation

/// 强力压制会话：临时把风扇压到最低转速，给用户时间关闭高负载软件。
/// 时长固定、自动到期，结束后有冷却期，防止连续压制让芯片长时间处于高温。
public struct Suppression: Sendable {
    public static let duration: Double = 60
    /// 冷却时长为实际压制时长的 2 倍，最多 120 秒
    public static let maxCooldown: Double = 120

    public enum StartResult: Equatable, Sendable {
        case started
        case alreadyActive
        case coolingDown(remaining: Double)
    }

    public private(set) var startedAt: Double?
    public private(set) var endsAt: Double?
    public private(set) var cooldownUntil: Double = -.infinity

    public init() {}

    public var isActive: Bool { endsAt != nil }

    public mutating func start(now: Double) -> StartResult {
        if isActive { return .alreadyActive }
        if now < cooldownUntil { return .coolingDown(remaining: cooldownUntil - now) }
        startedAt = now
        endsAt = now + Self.duration
        return .started
    }

    /// 结束会话（手动取消、安全中止或到期），并按实际用时进入冷却。
    public mutating func end(now: Double) {
        guard let start = startedAt, isActive else { return }
        let used = max(min(now, endsAt ?? now) - start, 0)
        cooldownUntil = now + min(used * 2, Self.maxCooldown)
        startedAt = nil
        endsAt = nil
    }

    /// 到期则自动结束；返回本次调用是否刚好到期。
    @discardableResult
    public mutating func expireIfNeeded(now: Double) -> Bool {
        guard let end = endsAt, now >= end else { return false }
        self.end(now: end)
        return true
    }

    public func remaining(now: Double) -> Double? {
        endsAt.map { max($0 - now, 0) }
    }

    public func cooldownRemaining(now: Double) -> Double? {
        !isActive && now < cooldownUntil ? cooldownUntil - now : nil
    }
}
