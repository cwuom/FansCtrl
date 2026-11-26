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
        if let end = model.suppressEndsAt, end > now {
            active(remaining: end.timeIntervalSince(now))
        } else if confirming {
            confirmation
        } else {
            idle(cooldown: model.suppressCooldownEndsAt.map { $0.timeIntervalSince(now) }.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    private func idle(cooldown: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirming = true
            } label: {
                Label(cooldown.map { "冷却中 · \(Int($0.rounded(.up))) 秒后可用" } ?? "强力压制 60 秒",
                      systemImage: "speaker.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(prominent: cooldown == nil)
            .tint(.indigo)
            .disabled(cooldown != nil || !status.controlSupported)
            .help("风扇噪音突然变大时使用：瞬间压到最低转速 60 秒")
            if let note = status.suppressNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
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
        .task(id: Int(remaining.rounded(.up)) == 0) {
            // 本地倒计时到 0 时向服务确认最新状态
            if Int(remaining.rounded(.up)) == 0 { await model.refresh() }
        }
    }
}
