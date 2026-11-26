import FanCore
import SwiftUI

// 托盘面板与主窗口共用的组件。

extension ControlState {
    var symbolName: String {
        switch self {
        case .system: return "applelogo"
        case .manual: return "slider.horizontal.3"
        case .capped: return "speaker.zzz"
        case .released: return "thermometer.high"
        case .emergency: return "exclamationmark.triangle.fill"
        case .sensorFault: return "sensor.tag.radiowaves.forward"
        case .paused: return "pause.circle"
        case .unsupported: return "nosign"
        case .suppressed: return "speaker.slash.fill"
        }
    }
}

extension FanProfile {
    /// 按本机风扇规格把策略换算成直观的说明
    func strategyDetail(for fans: [FanStatus]) -> String {
        let fan = fans.first
        func rpm(_ fraction: Double) -> String {
            guard let f = fan else { return "\(Int(fraction * 100))%" }
            return "\(Int((f.minRPM + fraction * (f.maxRPM - f.minRPM)).rounded())) RPM"
        }
        switch ProfilePolicy.forProfile(self) {
        case .system:
            return self == .smart ? "自动在 图书馆/安静/均衡/性能 间切换" : "不干预"
        case .cap(let c):
            return "封顶约 \(rpm(c))，过热自动放开"
        case .curve(let curve):
            return "\(Int(curve.handBackBelow ?? 0))°C 起主动调速"
        case .full:
            return "固定 \(rpm(1))"
        }
    }
}

struct StateChip: View {
    let state: ControlState
    /// 强力压制剩余秒数，压制中直接显示在状态胶囊里
    var countdown: Int? = nil

    var body: some View {
        Label(countdown.map { "强力压制 \($0) 秒" } ?? state.displayName,
              systemImage: countdown == nil ? state.symbolName : ControlState.suppressed.symbolName)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.state(state))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
            .accessibilityLabel(countdown.map { "强力压制中，剩余 \($0) 秒" } ?? "控制状态：\(state.displayName)")
    }
}

/// 后台服务比 App 旧时的提示，提供一键更新。
struct ServiceUpdateBanner: View {
    let model: StatusModel

    var body: some View {
        if model.needsServiceUpdate {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台服务需要更新").font(.subheadline.weight(.semibold))
                    Text(model.serviceLacksFeatures
                         ? "当前服务版本较旧，强力压制等新功能不可用。更新时会弹出管理员授权。"
                         : "服务版本 \(model.status?.daemonVersion ?? "旧版") 与本 App 需要的 \(BuildInfo.serviceVersion) 不一致，更新后最新修复才会生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("更新…") { model.installService() }
                    .glassButtonStyle(prominent: true)
                    .tint(.orange)
            }
            .padding(12)
            .glassCard(cornerRadius: 16, tint: Color.orange.opacity(0.14))
        }
    }
}

struct TemperatureMetric: View {
    let title: String
    let value: Double?
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))°" } ?? "--")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.temperature(value))
                .contentTransition(.numericText())
                .animation(.smooth, value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 温度")
        .accessibilityValue(value.map { "\(Int($0.rounded())) 摄氏度" } ?? "未知")
    }
}

struct FanGauge: View {
    let fan: FanStatus
    var large = false

    var body: some View {
        let rpm = fan.actualRPM ?? 0
        VStack(spacing: 4) {
            Gauge(value: min(rpm, fan.maxRPM), in: 0...fan.maxRPM) {
                Text("风扇")
            } currentValueLabel: {
                Text(rpm < 1 ? "停" : String(format: "%.1fk", rpm / 1000))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(rpm > fan.maxRPM * 0.6 ? Color.orange : Palette.fan)
            .scaleEffect(large ? 1.35 : 1)
            .frame(width: large ? 80 : nil, height: large ? 80 : nil)
            Text(fan.plannedRPM == nil ? "系统控制" : "手动 \(Int(fan.plannedRPM ?? 0))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("风扇 \(fan.index + 1)")
        .accessibilityValue(rpm < 1 ? "停转" : "\(Int(rpm)) 转每分钟")
    }
}

struct ProfileTile: View {
    let profile: FanProfile
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: profile.symbolName).font(.title3)
                Text(profile.displayName).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .glassButtonStyle(prominent: selected)
        .tint(selected ? Palette.profile(profile) : nil)
        .accessibilityLabel(profile.displayName)
        .accessibilityHint(profile.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 智能档旁边的“静音优先”开关。
struct QuietFirstToggle: View {
    let model: StatusModel
    let status: StatusSnapshot
    var showsLabel = false

    var body: some View {
        // 只在智能档下显示为打开：其他档位里该设置不生效，显示打开会误导
        Toggle(isOn: Binding(
            get: { status.quietFirst && status.selectedProfile == .smart },
            set: { v in Task { await model.setQuietFirst(v) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("静音优先")
                if showsLabel {
                    Text("图书馆、课堂、会议：只在静音档位之间切换").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .help("图书馆、课堂、会议：智能档只在静音档位之间切换")
    }
}

struct NoticeRow: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassCard(cornerRadius: 12, tint: tint.opacity(0.15))
    }
}

struct ServiceMissingView: View {
    let model: StatusModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fan.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("后台服务未安装").font(.headline)
            Text("调节风扇需要一个以管理员权限运行的小型后台服务。安装时会弹出系统授权窗口；卸载后风扇立即交还系统。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("安装后台服务…") { model.installService() }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard()
    }
}

/// 根据连接状态显示内容或对应的提示。
struct ConnectionGate<Content: View>: View {
    let model: StatusModel
    @ViewBuilder var content: (StatusSnapshot) -> Content

    var body: some View {
        switch model.connection {
        case .connected:
            if let s = model.status { content(s) }
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .notRunning:
            ServiceMissingView(model: model)
        case .denied:
            NoticeRow(text: "后台服务拒绝了当前用户。只有当前登录在屏幕前的用户可以控制风扇。")
        case .failed(let m):
            NoticeRow(text: m)
        }
    }
}
