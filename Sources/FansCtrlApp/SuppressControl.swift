import AppKit
import FanCore
import SwiftUI

/// 强力压制：先原位确认（菜单栏面板里弹系统对话框不可靠），开启后显示倒计时。
struct SuppressControl: View {
    let model: StatusModel
    let status: StatusSnapshot
    @State private var confirming = false

    static let warning = "开启强力压制会瞬间降低噪音 60 秒，请立刻关闭高负载软件。"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .animation(.smooth, value: confirming)
        .animation(.smooth, value: model.suppressEndsAt)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let left = model.suppressCountdown {
            active(remaining: Double(left))
        } else if confirming {
            confirmation
        } else {
            idle(cooldown: model.suppressCooldownEndsAt.map { $0.timeIntervalSince(now) }.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// 与“智能”档同一视觉语言的玻璃行：图标 + 标题/说明 + 右侧小按钮，而不是整条实心色块。
    private func idle(cooldown: Double?) -> some View {
        let available = cooldown == nil && status.controlSupported && !model.serviceLacksFeatures
        return HStack(spacing: 12) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(available ? Color.indigo : Color.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill((available ? Color.indigo : Color.secondary).opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("强力压制").font(.subheadline.weight(.semibold))
                Text(idleSubtitle(cooldown: cooldown))
                    .font(.caption2)
                    .foregroundStyle(status.suppressNote == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button(cooldown == nil ? "开启" : "\(Int((cooldown ?? 0).rounded(.up)))s") { confirming = true }
                .glassButtonStyle(prominent: false)
                .controlSize(.small)
                .tint(.indigo)
                .disabled(!available)
                .accessibilityLabel("开启强力压制")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 16)
        .help("风扇噪音突然变大时使用：瞬间压到最低转速 60 秒")
    }

    private func idleSubtitle(cooldown: Double?) -> String {
        if model.serviceLacksFeatures { return "需先更新后台服务" }
        if !status.controlSupported { return "本机不支持手动控制" }
        if let c = cooldown { return "冷却中，\(Int(c.rounded(.up))) 秒后可再次使用" }
        if let note = status.suppressNote { return note }
        return "风扇突然变吵时，瞬间静音 60 秒"
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("开启强力压制？", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(Self.warning).font(.callout)
            Text("压制期间风扇保持最低转速；温度过高时会自动提前结束，紧急保护始终有效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("取消") { confirming = false }
                    .glassButtonStyle(prominent: false)
                Spacer()
                Button {
                    confirming = false
                    Task { await model.setSuppress(true) }
                } label: {
                    Label("立即压制", systemImage: "speaker.slash.fill")
                }
                .glassButtonStyle(prominent: true)
                .tint(.indigo)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tint: Color.orange.opacity(0.12))
    }

    private func active(remaining: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("强力压制中", systemImage: "speaker.slash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Text("剩余 \(Int(remaining.rounded(.up))) 秒")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            ProgressView(value: max(remaining, 0), total: Suppression.duration)
                .tint(.indigo)
                .accessibilityLabel("强力压制剩余时间")
            Text("请立刻关闭高负载软件，否则压制结束后风扇会重新加速。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label("打开活动监视器", systemImage: "chart.bar.doc.horizontal")
                }
                .glassButtonStyle(prominent: false)
                Spacer()
                Button("提前结束") { Task { await model.setSuppress(false) } }
                    .glassButtonStyle(prominent: false)
            }
            .controlSize(.small)
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tint: Color.indigo.opacity(0.14))
    }
}
