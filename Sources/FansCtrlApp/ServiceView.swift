import AppKit
import FanCore
import SwiftUI

struct ServiceView: View {
    let model: StatusModel
    @AppStorage(AppPreferences.showWindowOnLaunch) private var showWindowOnLaunch = true
    @State private var confirmUninstall = false

    private static let selftestCommand = "sudo fanctl set system && sudo fanctl selftest"

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时打开", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("启动时显示主窗口", isOn: $showWindowOnLaunch)
                Text("关闭主窗口后 FansCtrl 会继续在菜单栏运行，风扇控制由后台服务负责，与 App 是否打开无关。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("后台服务") {
                LabeledContent("状态") {
                    Label(connectionText, systemImage: connectionSymbol)
                        .foregroundStyle(model.connection == .connected ? Color.green : Color.orange)
                }
                if let s = model.status {
                    LabeledContent("机型", value: s.model)
                    LabeledContent("风扇", value: s.fans.isEmpty ? "无" :
                        s.fans.map { "#\($0.index + 1) \(Int($0.minRPM))–\(Int($0.maxRPM)) RPM" }.joined(separator: "，"))
                    LabeledContent("手动控制", value: s.controlSupported ? "支持" : "不支持")
                    if s.dryRun { LabeledContent("模式", value: "演示（dry-run，不写入硬件）") }
                    if let e = s.lastError {
                        LabeledContent("最近提示") { Text(e).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
                    }
                }
                HStack {
                    Button(model.connection == .notRunning ? "安装后台服务…" : "重新安装后台服务…") { model.installService() }
                    Button("卸载…", role: .destructive) { confirmUninstall = true }
                        .disabled(model.connection == .notRunning)
                    Spacer()
                    Button("刷新") { Task { await model.refresh() } }
                }
            }

            Section {
                LabeledContent("命令") {
                    Text(Self.selftestCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Button("复制命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.selftestCommand, forType: .string)
                    model.message = "已复制自检命令"
                }
            } header: {
                Text("硬件自检")
            } footer: {
                Text("在终端运行：短暂把风扇设为约 25% 转速 8 秒，确认本机固件接受手动控制，结束后自动恢复系统控制。")
            }

            if let m = model.message {
                Section { Text(m).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("卸载后台服务？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { model.uninstallService() }
        } message: {
            Text("风扇会立即交还 macOS 控制，配置文件和日志会一并删除。")
        }
    }

    private var connectionText: String {
        switch model.connection {
        case .connected: return "运行中"
        case .unknown: return "检测中"
        case .notRunning: return "未安装或未运行"
        case .denied: return "拒绝访问"
        case .failed(let m): return m
        }
    }

    private var connectionSymbol: String {
        model.connection == .connected ? "checkmark.circle.fill" : "exclamationmark.circle"
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("FansCtrl").font(.largeTitle.weight(.semibold))
                Text("版本 \(version)").foregroundStyle(.secondary)
            }
            Text("为不同场景调节 Mac 风扇：在图书馆保持安静，在高负载时提前散热。支持 Apple Silicon 与 Intel Mac。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: 8) {
                Label("后台服务只接受档位切换命令，不开放任意硬件写入", systemImage: "lock.shield")
                Label("过热、传感器异常、睡眠与退出时自动交还系统控制", systemImage: "arrow.uturn.backward.circle")
                Label("系统默认档零后台开销，其余档位每 2 秒采样一次", systemImage: "leaf")
            }
            .font(.callout)
            .padding(20)
            .glassCard()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
