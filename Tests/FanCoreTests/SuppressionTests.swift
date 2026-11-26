import Testing
@testable import FanCore

private let spec = FanSpec(index: 0, minRPM: 2317, maxRPM: 6550)
private let fans = [FanSample(spec: spec, actualRPM: 6000, systemTargetRPM: nil)]

@Suite struct SuppressionSessionTests {
    @Test func runsForFixedDurationThenExpires() {
        var s = Suppression()
        let started = s.start(now: 100)
        #expect(started == .started)
        #expect(s.remaining(now: 130) == 30)
        let early = s.expireIfNeeded(now: 159)
        let onTime = s.expireIfNeeded(now: 160)
        #expect(!early)
        #expect(onTime)
        #expect(!s.isActive)
    }

    @Test func cooldownIsTwiceUsedTimeCapped() {
        var s = Suppression()
        _ = s.start(now: 0)
        s.end(now: 10)
        #expect(s.cooldownRemaining(now: 10) == 20)
        let refused = s.start(now: 25)
        #expect(refused == .coolingDown(remaining: 5))
        let again = s.start(now: 30)
        #expect(again == .started)
        s.expireIfNeeded(now: 90)
        #expect(s.cooldownRemaining(now: 90) == Suppression.maxCooldown)
    }

    @Test func cannotStackSessions() {
        var s = Suppression()
        _ = s.start(now: 0)
        let second = s.start(now: 5)
        #expect(second == .alreadyActive)
        #expect(s.remaining(now: 5) == 55, "重复开启不能延长时长")
    }
}

@Suite struct ControllerSuppressionTests {
    @Test(arguments: [FanProfile.system, .library, .balanced, .performance, .max, .smart])
    func dropsToMinimumImmediately(profile: FanProfile) {
        var c = FanController()
        let d = c.step(profile: profile, temp: 90, thermal: .serious, fans: fans, now: 0, suppress: true)
        #expect(d.state == .suppressed)
        #expect(d.targets == [0: spec.minRPM], "不走斜率，瞬间压到最低转速")
    }

    @Test func abortsWhenTooHot() {
        var c = FanController()
        _ = c.step(profile: .balanced, temp: 95, thermal: .nominal, fans: fans, now: 0, suppress: true)
        // 温度经过平滑，单次尖峰不会中止；持续高温在数个采样内中止
        var d = ControlDecision.automatic(.system)
        for i in 1...4 {
            d = c.step(profile: .balanced, temp: 104, thermal: .nominal, fans: fans, now: Double(i) * 2, suppress: true)
        }
        #expect(d == .automatic(.released))
    }

    @Test func emergencyOverridesSuppression() {
        var c = FanController()
        let hot = c.step(profile: .library, temp: 108, thermal: .nominal, fans: fans, now: 0, suppress: true)
        #expect(hot.state == .emergency)
        var c2 = FanController()
        let critical = c2.step(profile: .library, temp: 70, thermal: .critical, fans: fans, now: 0, suppress: true)
        #expect(critical.state == .emergency)
    }

    @Test func missingSensorAbortsSuppression() {
        var c = FanController()
        let d = c.step(profile: .system, temp: nil, thermal: .nominal, fans: fans, now: 0, suppress: true)
        #expect(d == .automatic(.sensorFault))
    }

    @Test func rampsBackUpGraduallyAfterSuppression() throws {
        var c = FanController()
        _ = c.step(profile: .performance, temp: 90, thermal: .nominal, fans: fans, now: 0, suppress: true)
        let d = c.step(profile: .performance, temp: 90, thermal: .nominal, fans: fans, now: 2)
        let rpm = try #require(d.targets?[0])
        #expect(rpm > spec.minRPM && rpm <= spec.minRPM + 600 * 2, "结束后按斜率回升，不会突然满速")
    }
}
