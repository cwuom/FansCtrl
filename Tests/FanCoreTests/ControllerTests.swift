import Testing
@testable import FanCore

private let spec = FanSpec(index: 0, minRPM: 2317, maxRPM: 6550)
private let libraryCeiling = 2317 + 0.12 * (6550 - 2317)

private func sample(actual: Double? = 0, system: Double? = 0) -> [FanSample] {
    [FanSample(spec: spec, actualRPM: actual, systemTargetRPM: system)]
}

@Suite struct CurveTests {
    @Test func interpolatesAndClamps() {
        let c = FanCurve(handBackBelow: nil, points: [(50, 0.2), (70, 0.6), (90, 1)])
        #expect(c.fraction(at: 30) == 0.2)
        #expect(abs(c.fraction(at: 60) - 0.4) < 1e-9)
        #expect(c.fraction(at: 90) == 1)
        #expect(c.fraction(at: 120) == 1)
    }
}

@Suite struct ControllerTests {
    @Test func systemProfileNeverTakesControl() {
        var c = FanController()
        let d = c.step(profile: .system, temp: 110, thermal: .critical, fans: sample(), now: 0)
        #expect(d == .automatic(.system))
    }

    @Test func missingTemperatureHandsBackToSystem() {
        var c = FanController()
        _ = c.step(profile: .max, temp: 60, thermal: .nominal, fans: sample(), now: 0)
        let d = c.step(profile: .max, temp: nil, thermal: .nominal, fans: sample(), now: 2)
        #expect(d == .automatic(.sensorFault))
    }

    @Test func emergencyForcesMaxWithHysteresis() {
        var c = FanController()
        var d = c.step(profile: .library, temp: 108, thermal: .nominal, fans: sample(), now: 0)
        #expect(d.state == .emergency)
        #expect(d.targets == [0: 6550])
        d = c.step(profile: .library, temp: 102, thermal: .nominal, fans: sample(), now: 2)
        #expect(d.state == .emergency, "未降到恢复阈值前保持满速")
        d = c.step(profile: .library, temp: 99, thermal: .nominal, fans: sample(), now: 4)
        #expect(d.state != .emergency)
    }

    @Test func criticalThermalPressureIsEmergency() {
        var c = FanController()
        let d = c.step(profile: .quiet, temp: 70, thermal: .critical, fans: sample(), now: 0)
        #expect(d.state == .emergency)
    }

    @Test func intelThresholdsAreLower() {
        var c = FanController(tuning: .intel)
        #expect(c.step(profile: .library, temp: 99, thermal: .nominal, fans: sample(), now: 0).state == .emergency)
    }

    @Test func libraryStaysOutWhileSystemIsQuieter() {
        var c = FanController()
        let d = c.step(profile: .library, temp: 90, thermal: .nominal, fans: sample(actual: 2500, system: 2500), now: 0)
        #expect(d == .automatic(.system), "系统本来就比封顶安静时不接管，保证不比系统更吵")
    }

    @Test func libraryCapsLoudSystemAndRampsDownSmoothly() throws {
        var c = FanController()
        var d = c.step(profile: .library, temp: 90, thermal: .nominal, fans: sample(actual: 5000, system: 5000), now: 0)
        #expect(d.state == .capped)
        let first = try #require(d.targets?[0])
        #expect(first < 5000 && first >= 5000 - 250 * 2 - 1, "按降速斜率平滑回落，不突变")
        var t = 0.0
        for _ in 0..<20 {
            t += 2
            d = c.step(profile: .library, temp: 90, thermal: .nominal, fans: sample(actual: d.targets?[0], system: nil), now: t)
        }
        let settled = try #require(d.targets?[0])
        #expect(abs(settled - libraryCeiling) <= ControllerTuning.appleSilicon.deadbandRPM)
    }

    @Test func libraryDoesNotRaiseFanBelowCeiling() throws {
        let fans = [
            FanSample(spec: spec, actualRPM: 5000, systemTargetRPM: 5000),
            FanSample(spec: FanSpec(index: 1, minRPM: 2317, maxRPM: 6550), actualRPM: 2400, systemTargetRPM: 2400),
        ]
        var c = FanController()
        let d = c.step(profile: .library, temp: 90, thermal: .nominal, fans: fans, now: 0)
        #expect(try #require(d.targets?[1]) <= 2400 + 1)
    }

    @Test func libraryReleasesWhenTooHotOrThrottling() {
        var c = FanController()
        _ = c.step(profile: .library, temp: 90, thermal: .nominal, fans: sample(actual: 5000, system: 5000), now: 0)
        var d = c.step(profile: .library, temp: 90, thermal: .serious, fans: sample(actual: 3000, system: nil), now: 2)
        #expect(d == .automatic(.released), "系统热压力 serious 时放开封顶，避免性能受损")

        c.reset()
        d = c.step(profile: .library, temp: 104, thermal: .nominal, fans: sample(), now: 0)
        #expect(d == .automatic(.released))
        d = c.step(profile: .library, temp: 99, thermal: .nominal, fans: sample(), now: 2)
        #expect(d == .automatic(.released), "回差内保持放开")
    }

    @Test func capRetriesSystemAfterCoolingDown() {
        var c = FanController()
        _ = c.step(profile: .library, temp: 90, thermal: .nominal, fans: sample(actual: 5000, system: 5000), now: 0)
        // 降到交还阈值（Apple Silicon 60°C）以下才交还系统
        var d = c.step(profile: .library, temp: 50, thermal: .nominal, fans: sample(actual: 3000, system: nil), now: 2)
        for i in 2..<20 where d.state == .capped {
            d = c.step(profile: .library, temp: 50, thermal: .nominal, fans: sample(actual: 3000, system: nil), now: Double(i) * 2)
        }
        #expect(d == .automatic(.system))
    }

    @Test func balancedHandsBackBelowThresholdWithHysteresis() {
        var c = FanController()
        #expect(c.step(profile: .balanced, temp: 50, thermal: .nominal, fans: sample(), now: 0) == .automatic(.system))
        #expect(c.step(profile: .balanced, temp: 85, thermal: .nominal, fans: sample(), now: 2).state == .manual)
        var d = ControlDecision.automatic(.system)
        for i in 2..<40 {
            d = c.step(profile: .balanced, temp: 58, thermal: .nominal, fans: sample(), now: Double(i) * 2)
        }
        #expect(d.state == .manual, "58°C 仍在 60-4 的回差内")
        for i in 40..<80 {
            d = c.step(profile: .balanced, temp: 50, thermal: .nominal, fans: sample(), now: Double(i) * 2)
        }
        #expect(d == .automatic(.system))
    }

    @Test func rampUpIsRateLimited() throws {
        var c = FanController()
        let d = c.step(profile: .performance, temp: 95, thermal: .nominal, fans: sample(actual: 2400, system: 2400), now: 0)
        #expect(try #require(d.targets?[0]) <= 2400 + 600 * 2)
    }

    @Test func maxProfileReachesFull() {
        var c = FanController()
        var d = ControlDecision.automatic(.system)
        for i in 0..<20 {
            d = c.step(profile: .max, temp: 40, thermal: .nominal, fans: sample(actual: d.targets?[0] ?? 0), now: Double(i) * 2)
        }
        #expect(d.targets == [0: 6550])
    }

    @Test(arguments: FanProfile.allCases)
    func targetsAlwaysWithinFanRange(profile: FanProfile) {
        var c = FanController()
        var gen = SystemRandomNumberGenerator()
        var actual: Double? = 0
        for i in 0..<300 {
            let temp = Double.random(in: 20...115, using: &gen)
            let thermal = ThermalLevel(rawValue: Int.random(in: 0...3, using: &gen))!
            let sys = Double.random(in: 0...7000, using: &gen)
            let d = c.step(profile: profile, temp: temp, thermal: thermal,
                           fans: sample(actual: actual, system: sys), now: Double(i) * 2)
            if let t = d.targets?[0] {
                #expect(t >= spec.minRPM && t <= spec.maxRPM)
                actual = t
            }
        }
    }
}

@Suite struct SmartSelectorTests {
    private func run(_ s: inout SmartSelector, load: Double, battery: Bool = false, thermal: ThermalLevel = .nominal,
                     quietFirst: Bool = false, from: Double, to: Double) -> FanProfile {
        var t = from
        var p = s.current
        while t <= to {
            p = s.step(SmartInputs(cpuLoad: load, onBattery: battery, thermal: thermal, quietFirst: quietFirst, now: t))
            t += 2
        }
        return p
    }

    @Test func firstSampleAppliesImmediately() {
        var s = SmartSelector()
        #expect(s.step(SmartInputs(cpuLoad: 0.05, onBattery: true, thermal: .nominal, quietFirst: false, now: 0)) == .library)
    }

    @Test func sustainedLoadUpgradesToPerformanceOnAC() {
        var s = SmartSelector()
        _ = run(&s, load: 0.05, from: 0, to: 0)
        #expect(run(&s, load: 1, from: 2, to: 8) != .performance, "短时尖峰不应立即升到性能档")
        #expect(run(&s, load: 1, from: 10, to: 80) == .performance)
    }

    @Test func batteryCapsAtBalanced() {
        var s = SmartSelector()
        #expect(run(&s, load: 1, battery: true, from: 0, to: 120) == .balanced)
    }

    @Test func downgradeIsSlowerThanUpgrade() {
        var s = SmartSelector()
        _ = run(&s, load: 1, from: 0, to: 120)
        #expect(s.current == .performance)
        #expect(run(&s, load: 0, from: 122, to: 150) != .quiet)
        #expect(run(&s, load: 0, from: 152, to: 400) == .quiet)
    }

    @Test func thermalPressureUpgradesImmediately() {
        var s = SmartSelector()
        _ = run(&s, load: 0.1, from: 0, to: 10)
        #expect(s.step(SmartInputs(cpuLoad: 0.1, onBattery: false, thermal: .serious, quietFirst: false, now: 12)) == .performance)
    }

    /// 回归：切换“静音优先”属于用户主动意图，必须立即生效，不能等 45 秒降档驻留
    @Test func togglingQuietFirstAppliesImmediately() {
        var s = SmartSelector()
        _ = run(&s, load: 1, from: 0, to: 120)
        #expect(s.current == .performance)
        let p = s.step(SmartInputs(cpuLoad: 1, onBattery: false, thermal: .nominal, quietFirst: true, now: 122))
        #expect(p == .quiet)
        #expect(s.reason.hasPrefix("静音优先"))
        let back = s.step(SmartInputs(cpuLoad: 1, onBattery: false, thermal: .nominal, quietFirst: false, now: 124))
        #expect(back == .performance)
    }

    @Test func quietFirstStaysInQuietProfiles() {
        var s = SmartSelector()
        #expect(run(&s, load: 0.1, quietFirst: true, from: 0, to: 60) == .library)
        let p = run(&s, load: 1, thermal: .serious, quietFirst: true, from: 62, to: 300)
        #expect(p == .quiet, "静音优先下不会升到均衡/性能，过热由控制器安全阀兜底")
    }
}
