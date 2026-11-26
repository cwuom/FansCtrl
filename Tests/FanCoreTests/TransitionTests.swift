import Testing
@testable import FanCore

/// 回归：切换档位时转速不能突变（用户反馈“切换档位时忽然有噪音”）
@Suite struct TransitionTests {
    private let spec = FanSpec(index: 0, minRPM: 2317, maxRPM: 6550)
    private var up: Double { ControllerTuning.appleSilicon.rampUpPerSecond }
    private var down: Double { ControllerTuning.appleSilicon.rampDownPerSecond }

    private func fans(actual: Double?, system: Double? = nil) -> [FanSample] {
        [FanSample(spec: spec, actualRPM: actual, systemTargetRPM: system)]
    }

    /// 驱动若干步，返回每步的目标转速（nil 表示交还系统）
    private func run(_ c: inout FanController, _ profile: FanProfile, temp: Double, from t0: Double, steps: Int,
                     actual: inout Double) -> [Double?] {
        var out: [Double?] = []
        for i in 0..<steps {
            let d = c.step(profile: profile, temp: temp, thermal: .nominal, fans: fans(actual: actual), now: t0 + Double(i) * 2)
            let target = d.targets?[0]
            if let target { actual = target }
            out.append(target)
        }
        return out
    }

    @Test func maxProfileRampsUpInsteadOfJumping() throws {
        var c = FanController()
        let d = c.step(profile: .max, temp: 60, thermal: .nominal, fans: fans(actual: 2400, system: 2400), now: 0)
        let first = try #require(d.targets?[0])
        #expect(first <= 2400 + up * 2 + 1)
    }

    @Test func manualToCapNeverHandsBackInBetween() {
        var c = FanController()
        var actual = 2400.0
        _ = run(&c, .performance, temp: 85, from: 0, steps: 10, actual: &actual)
        #expect(actual > 4000)
        c.profileChanged()
        let targets = run(&c, .library, temp: 85, from: 20, steps: 20, actual: &actual)
        #expect(!targets.contains(where: { $0 == nil }), "从手动档切到封顶档不能先交还系统（会被系统突然拉高）")
        var prev = 4000.0
        for t in targets.compactMap({ $0 }) {
            #expect(prev - t <= down * 2 + 1, "降速必须平滑")
            prev = t
        }
        #expect(abs(actual - (2317 + 0.12 * (6550 - 2317))) <= 80, "最终平滑落到封顶值")
    }

    @Test func profileChangeKeepsContinuity() throws {
        var c = FanController()
        var actual = 2400.0
        _ = run(&c, .performance, temp: 85, from: 0, steps: 10, actual: &actual)
        let before = actual
        c.profileChanged()
        let d = c.step(profile: .balanced, temp: 85, thermal: .nominal, fans: fans(actual: before), now: 20)
        let after = try #require(d.targets?[0])
        #expect(abs(after - before) <= max(up, down) * 2 + 1)
    }

    @Test func capReleasesOnlyWhenTrulyCool() {
        var c = FanController()
        _ = c.step(profile: .library, temp: 85, thermal: .nominal, fans: fans(actual: 5000, system: 5000), now: 0)
        var d = ControlDecision.automatic(.system)
        for i in 1...30 {
            d = c.step(profile: .library, temp: 66, thermal: .nominal, fans: fans(actual: 2830), now: Double(i) * 2)
        }
        #expect(d.state == .capped, "66°C 时系统多半仍想高转速，交还会立刻再被封顶，造成忽高忽低")
        for i in 31...60 {
            d = c.step(profile: .library, temp: 50, thermal: .nominal, fans: fans(actual: 2830), now: Double(i) * 2)
        }
        #expect(d == .automatic(.system))
    }
}
