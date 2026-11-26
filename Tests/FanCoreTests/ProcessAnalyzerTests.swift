import Foundation
import Testing
@testable import FanCore

private let MB: UInt64 = 1_048_576
private let GB: UInt64 = 1_073_741_824
private let selfPID: Int32 = 999

private func proc(_ pid: Int32, _ path: String, cpuSec: Double = 0, mem: UInt64 = 50 * MB, ppid: Int32 = 1,
                  name: String? = nil) -> ProcessSample {
    ProcessSample(pid: pid, ppid: ppid, uid: 501, name: name ?? (path as NSString).lastPathComponent, path: path,
                  cpuTimeNs: UInt64(cpuSec * 1e9), footprint: mem, startTime: 1000)
}

private let chromePath = "/Applications/Google Chrome.app"
private let chromeApp = AppContext(pid: 10, name: "Google Chrome", bundleID: "com.google.Chrome",
                                   bundlePath: chromePath, isRegular: true, windowCount: 2)

@Suite struct ProcessAnalyzerTests {
    private func update(_ a: inout ProcessAnalyzer, _ samples: [ProcessSample], apps: [AppContext] = [chromeApp],
                        front: Int32? = nil, now: Double) -> [ProcessGroup] {
        a.update(samples: samples, apps: apps, frontmostPID: front, selfPID: selfPID, totalMemory: 16 * GB, now: now)
    }

    @Test func bundleRootUsesOutermostApp() {
        #expect(ProcessAnalyzer.bundleRoot(of: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == chromePath)
        #expect(ProcessAnalyzer.bundleRoot(of: "/usr/bin/ssh") == nil)
    }

    @Test func helpersAreGroupedUnderTheirApp() throws {
        var a = ProcessAnalyzer()
        let samples = [
            proc(10, "\(chromePath)/Contents/MacOS/Google Chrome", mem: 300 * MB, ppid: 1),
            proc(11, "\(chromePath)/Contents/Frameworks/H.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", mem: 200 * MB, ppid: 10),
            proc(12, "\(chromePath)/Contents/Frameworks/H.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", mem: 100 * MB, ppid: 10),
        ]
        let groups = update(&a, samples, now: 0)
        let chrome = try #require(groups.first { $0.id == chromePath })
        #expect(chrome.pids == [10, 11, 12])
        #expect(chrome.footprint == 600 * MB)
        #expect(chrome.name == "Google Chrome")
        #expect(chrome.plan == .quitApp(pid: 10), "普通 App 走正常退出，让它有机会提示保存")
    }

    @Test func sustainedBackgroundCPUIsFlaggedButNotForegroundOrSpikes() throws {
        var a = ProcessAnalyzer()
        let path = "\(chromePath)/Contents/MacOS/Google Chrome"
        _ = update(&a, [proc(10, path, cpuSec: 0)], now: 0)
        // 短暂尖峰：只持续 4 秒，不应报警
        var g = update(&a, [proc(10, path, cpuSec: 2)], now: 2)
        g = update(&a, [proc(10, path, cpuSec: 4)], now: 4)
        #expect(g.first?.anomalies.isEmpty == true)
        // 持续 60 秒满载一个核心
        var cpu = 4.0
        for t in stride(from: 6.0, through: 64.0, by: 2) {
            cpu += 2
            g = update(&a, [proc(10, path, cpuSec: cpu)], now: t)
        }
        let bg = try #require(g.first)
        #expect(bg.anomalies.contains { if case .sustainedCPU = $0 { return true }; return false })
        #expect(bg.isRecommended)

        // 同样的负载，如果是用户正在使用的前台 App，不建议结束
        cpu += 2
        let fg = update(&a, [proc(10, path, cpuSec: cpu)], front: 10, now: 66)
        #expect(fg.first?.isRecommended == false)
    }

    @Test func memoryGrowthNeedsLongObservation() throws {
        var a = ProcessAnalyzer()
        let path = "/Applications/Leaky.app/Contents/MacOS/Leaky"
        let leaky = AppContext(pid: 20, name: "Leaky", bundleID: nil, bundlePath: "/Applications/Leaky.app", isRegular: true, windowCount: 1)
        var g: [ProcessGroup] = []
        for i in 0...40 {
            let mem = 400 * MB + UInt64(i) * 40 * MB   // 8 秒一次，80 秒内 +1.6GB
            g = update(&a, [proc(20, path, mem: mem)], apps: [leaky], now: Double(i) * 8)
        }
        let group = try #require(g.first)
        #expect(group.anomalies.contains { if case .memoryGrowth = $0 { return true }; return false },
                "观察满 5 分钟后应识别持续增长")
    }

    @Test func windowlessHeavyAppFlagged() throws {
        var a = ProcessAnalyzer()
        let preview = AppContext(pid: 30, name: "Pages", bundleID: "com.apple.iWork.Pages",
                                 bundlePath: "/Applications/Pages.app", isRegular: true, windowCount: 0)
        let g = update(&a, [proc(30, "/Applications/Pages.app/Contents/MacOS/Pages", mem: 800 * MB)], apps: [preview], now: 0)
        let pages = try #require(g.first)
        #expect(pages.anomalies == [.windowlessHeavyApp(bytes: 800 * MB)])
        #expect(pages.isRecommended)
    }

    @Test func orphanedHelpersFlaggedOnlyWhenMainAppGone() throws {
        var a = ProcessAnalyzer()
        let helper = "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let g = update(&a, [proc(40, helper, mem: 400 * MB), proc(41, helper, mem: 200 * MB)], apps: [], now: 0)
        let code = try #require(g.first)
        #expect(code.anomalies.contains(.orphanedHelpers))
        #expect(code.plan == .terminate(pids: [40, 41]))
    }

    @Test(arguments: [
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", ProcessProtection.critical),
        ("/usr/libexec/trustd", ProcessProtection.system),
        ("/System/Library/PrivateFrameworks/X.framework/x", ProcessProtection.system),
    ])
    func protectedProcessesNeverRecommended(path: String, expected: ProcessProtection) throws {
        var a = ProcessAnalyzer()
        let g = update(&a, [proc(50, path, mem: 6 * GB)], apps: [], now: 0)
        let group = try #require(g.first)
        #expect(group.protection == expected)
        #expect(!group.isRecommended)
        #expect(group.plan == nil)
    }

    @Test func selfIsProtected() throws {
        var a = ProcessAnalyzer()
        let g = update(&a, [proc(selfPID, "/Applications/FansCtrl.app/Contents/MacOS/FansCtrl", mem: 6 * GB)], apps: [], now: 0)
        #expect(try #require(g.first).protection == .selfApp)
    }

    @Test func pidReuseDoesNotProduceBogusCPU() {
        var a = ProcessAnalyzer()
        _ = update(&a, [proc(60, "/opt/tool", cpuSec: 1000)], apps: [], now: 0)
        var reused = proc(60, "/opt/tool", cpuSec: 1)
        reused.startTime = 2000
        let g = update(&a, [reused], apps: [], now: 2)
        #expect(g.first?.cpuPercent ?? 0 <= 0.0001)
    }

    @Test func vanishedGroupsAreForgotten() {
        var a = ProcessAnalyzer()
        _ = update(&a, [proc(70, "/opt/a"), proc(71, "/opt/b")], apps: [], now: 0)
        let g = update(&a, [proc(70, "/opt/a")], apps: [], now: 2)
        #expect(g.map(\.id) == ["pid:70"])
    }

    @Test func recommendationsRankedByImpact() {
        var a = ProcessAnalyzer()
        let small = AppContext(pid: 80, name: "Small", bundleID: nil, bundlePath: "/Applications/Small.app", isRegular: true, windowCount: 0)
        let big = AppContext(pid: 81, name: "Big", bundleID: nil, bundlePath: "/Applications/Big.app", isRegular: true, windowCount: 0)
        let g = update(&a, [
            proc(80, "/Applications/Small.app/Contents/MacOS/Small", mem: 600 * MB),
            proc(81, "/Applications/Big.app/Contents/MacOS/Big", mem: 4 * GB),
        ], apps: [small, big], now: 0)
        #expect(g.filter(\.isRecommended).map(\.name) == ["Big", "Small"])
    }
}
