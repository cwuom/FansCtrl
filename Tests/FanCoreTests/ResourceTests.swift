import AppKit
import Darwin
import Foundation
import Testing
@testable import FanCore

/// 在本机真实采样，校验单位换算与口径（不修改系统任何状态）
@Suite struct SamplingIntegrationTests {
    @Test func cpuTimeIsInNanoseconds() throws {
        let me = getpid()
        let before = try #require(ProcessSampler.sample(pid: me)).cpuTimeNs
        let start = Date()
        var x = 0.0
        while Date().timeIntervalSince(start) < 0.5 { x += sin(x) + 1 }
        let after = try #require(ProcessSampler.sample(pid: me)).cpuTimeNs
        let seconds = Double(after - before) / 1e9
        #expect(x > 0)
        #expect(seconds > 0.3 && seconds < 0.8, "忙等 0.5 秒应得到约 0.5 秒 CPU 时间，实际 \(seconds)")
    }

    @Test func samplesOwnProcessesOnly() {
        let all = ProcessSampler.sample()
        #expect(all.contains { $0.pid == getpid() })
        #expect(all.allSatisfy { $0.uid == getuid() })
        #expect(all.allSatisfy { $0.footprint > 0 || $0.cpuTimeNs >= 0 })
    }

    @Test func resourceSnapshotIsSane() throws {
        let r = SystemResources.sample()
        let m = try #require(r.memory)
        #expect(m.total == ProcessInfo.processInfo.physicalMemory)
        #expect(m.used > 0 && m.used <= m.total)
        #expect(m.available + m.used == m.total)
        let d = try #require(r.disk)
        #expect(d.available > 0 && d.available <= d.total)
        #expect(try #require(r.uptime) > 0)
    }
}

@Suite struct RealProcessAnalysisTests {
    /// 用本机真实进程跑分析器：受保护的进程永远不能出现在建议里，自身必须受保护
    @Test func realProcessesNeverRecommendProtected() async throws {
        var analyzer = ProcessAnalyzer()
        let total = ProcessInfo.processInfo.physicalMemory
        // 与 App 相同：提供运行中应用的信息，否则正在运行的应用会被误判为“主程序已退出”
        let apps = NSWorkspace.shared.runningApplications.map {
            AppContext(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier,
                       bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular, windowCount: 1)
        }
        _ = analyzer.update(samples: ProcessSampler.sample(), apps: apps, frontmostPID: nil, selfPID: getpid(),
                            totalMemory: total, now: 0)
        try await Task.sleep(for: .milliseconds(600))
        let groups = analyzer.update(samples: ProcessSampler.sample(), apps: apps, frontmostPID: nil, selfPID: getpid(),
                                     totalMemory: total, now: 0.6)
        let runningBundles = Set(apps.compactMap(\.bundlePath))
        #expect(!groups.contains { $0.anomalies.contains(.orphanedHelpers) && runningBundles.contains($0.id) },
                "正在运行的应用不能被判为“主程序已退出”")
        #expect(!groups.isEmpty)
        #expect(groups.filter(\.isRecommended).allSatisfy { $0.protection == nil && $0.plan != nil })
        #expect(groups.first { $0.pids.contains(getpid()) }?.protection == .selfApp)
        let finder = groups.first { $0.name == "Finder" }
        #expect(finder == nil || finder?.isRecommended == false)
        print("[real] groups=\(groups.count) recommended=\(groups.filter(\.isRecommended).map { "\($0.name):\($0.anomalies.map(\.title))" })")
    }
}

@Suite struct HealthAdvisorTests {
    private let gb: UInt64 = 1_073_741_824

    private func memory(swap: UInt64 = 0, pressure: MemoryPressure = .normal) -> MemoryStats {
        MemoryStats(total: 16 * gb, used: 8 * gb, appMemory: 6 * gb, wired: 1 * gb, compressed: 1 * gb,
                    swapUsed: swap, swapTotal: swap, pressure: pressure)
    }

    @Test func memoryFromPagesMatchesActivityMonitor() {
        let m = MemoryStats.from(pageSize: 16384, internalPages: 100_000, purgeablePages: 10_000, wiredPages: 20_000,
                                 compressorPages: 5_000, total: 32 * gb, swapUsed: 0, swapTotal: 0, pressure: .normal)
        #expect(m.appMemory == 90_000 * 16384)
        #expect(m.used == (90_000 + 20_000 + 5_000) * 16384)
        #expect(m.available == 32 * gb - m.used)
    }

    @Test func healthyMachineHasNoIssues() {
        let r = ResourceSnapshot(memory: memory(), disk: DiskStats(total: 1000 * gb, available: 400 * gb), uptime: 3600)
        #expect(HealthAdvisor.evaluate(r).isEmpty)
    }

    @Test func flagsLongRunningStressedMachine() {
        let r = ResourceSnapshot(memory: memory(swap: 9 * gb, pressure: .warning),
                                 disk: DiskStats(total: 500 * gb, available: 8 * gb), uptime: 30 * 86_400)
        let ids = HealthAdvisor.evaluate(r)
        #expect(Set(ids.map(\.id)) == ["pressure", "swap", "disk", "uptime"])
        #expect(ids.first?.severity == .critical, "严重问题排在最前")
    }

    @Test func swapThresholdScalesWithRAM() {
        let small = ResourceSnapshot(memory: memory(swap: 3 * gb), disk: nil, uptime: nil)
        #expect(HealthAdvisor.evaluate(small).isEmpty, "16GB 机器上 3GB 交换不足 25%，不报警")
        let big = ResourceSnapshot(memory: memory(swap: 5 * gb), disk: nil, uptime: nil)
        #expect(HealthAdvisor.evaluate(big).first?.id == "swap")
    }
}
