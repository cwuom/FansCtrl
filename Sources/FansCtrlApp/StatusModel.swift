import FanCore
import Foundation
import Observation
import ServiceManagement

enum Connection: Equatable {
    case unknown
    case connected
    case notRunning
    case denied
    case failed(String)
}

/// 温度/转速历史采样，用于主窗口曲线。
struct HistorySample: Identifiable, Equatable {
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let rpm: Double?
    var id: Date { date }
}

@MainActor
@Observable
final class StatusModel {
    private(set) var status: StatusSnapshot?
    private(set) var connection: Connection = .unknown
    private(set) var pendingProfile: FanProfile?
    private(set) var history: [HistorySample] = []
    /// 强力压制结束/冷却结束的绝对时间，界面据此每秒本地倒计时，无需高频轮询
    private(set) var suppressEndsAt: Date?
    private(set) var suppressCooldownEndsAt: Date?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var message: String?

    /// 保留 5 分钟（2 秒一个点）
    static let historyLimit = 150
    static let pollInterval: Duration = .seconds(2)

    private var observers = 0
    private var pollTask: Task<Void, Never>?
    private let client = IPCClient()

    var selectedProfile: FanProfile? { pendingProfile ?? status?.selectedProfile }

    // MARK: - 轮询

    /// 托盘面板与主窗口各自登记；只要有一个可见就轮询，全部收起后停止，空闲时零开销。
    func beginObserving() {
        observers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.perform(.status)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func endObserving() {
        observers = max(observers - 1, 0)
        guard observers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async { await perform(.status) }

    // MARK: - 命令

    func select(_ profile: FanProfile) async {
        pendingProfile = profile
        await perform(.setProfile(profile))
        pendingProfile = nil
    }

    /// “静音优先”只对智能档有意义：在其他档位打开时顺带切到智能档，避免开关无效果
    func setSuppress(_ on: Bool) async {
        await perform(.setSuppress(on), surfaceErrors: true)
    }

    func setQuietFirst(_ value: Bool) async {
        if status?.quietFirst != value { await perform(.setQuietFirst(value)) }
        if value, status?.selectedProfile != .smart { await select(.smart) }
    }

    /// - Parameter surfaceErrors: 业务拒绝（如冷却中）以提示展示，不当作连接故障
    private func perform(_ command: IPCCommand, surfaceErrors: Bool = false) async {
        let client = self.client
        // IPC 是同步阻塞调用（带 2 秒超时），放到后台线程避免卡住界面
        let result = await Task.detached(priority: .userInitiated) {
            Result { try client.send(command) }
        }.value
        switch result {
        case .success(let s):
            status = s
            connection = .connected
            let now = Date()
            suppressEndsAt = s.suppressRemaining.map { now.addingTimeInterval($0) }
            suppressCooldownEndsAt = s.suppressCooldown.map { now.addingTimeInterval($0) }
            record(s)
        case .failure(IPCError.io(let m)) where surfaceErrors:
            message = m
            await perform(.status)
        case .failure(let error as IPCError):
            switch error {
            case .notRunning: connection = .notRunning
            case .permissionDenied: connection = .denied
            default: connection = .failed(error.description)
            }
        case .failure(let error):
            connection = .failed(error.localizedDescription)
        }
    }

    private func record(_ s: StatusSnapshot) {
        let now = Date()
        // 切档等命令会紧接着返回状态，1 秒内的重复点不入曲线
        if let last = history.last, now.timeIntervalSince(last.date) < 1 { return }
        let rpms = s.fans.compactMap(\.actualRPM)
        history.append(HistorySample(date: now, cpu: s.cpuTemp, gpu: s.gpuTemp,
                                     rpm: rpms.isEmpty ? nil : rpms.max()))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    // MARK: - 后台服务与登录项

    func installService() {
        do {
            try ServiceInstaller.run(script: "install")
            message = "后台服务已安装"
        } catch {
            message = "\(error)"
        }
        Task { await refresh() }
    }

    func uninstallService() {
        do {
            try ServiceInstaller.run(script: "uninstall")
            message = "后台服务已卸载，风扇已交还系统"
            status = nil
        } catch {
            message = "\(error)"
        }
        Task { await refresh() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "登录项设置失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
