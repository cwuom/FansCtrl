import FanCore
import SwiftUI

struct ProfilesView: View {
    let model: StatusModel
    let status: StatusSnapshot

    private let profiles: [FanProfile] = [.library, .quiet, .balanced, .performance, .max, .system]
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            smartCard
            Text("固定档位").font(.headline).foregroundStyle(.secondary)
            GlassGroup(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(profiles, id: \.self) { p in
                        ProfileCard(profile: p, fans: status.fans, selected: model.selectedProfile == p) {
                            Task { await model.select(p) }
                        }
                    }
                }
            }
            safetyCard
        }
    }

    private var smartCard: some View {
        let selected = model.selectedProfile == .smart
        return HStack(alignment: .center, spacing: 18) {
            Image(systemName: FanProfile.smart.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(Palette.profile(.smart))
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("智能").font(.title3.weight(.semibold))
                Text(FanProfile.smart.summary).font(.callout).foregroundStyle(.secondary)
                if selected {
                    Text("当前：\(status.activeProfile.displayName) · \(status.smartReason ?? "")")
                        .font(.caption)
                        .foregroundStyle(Palette.profile(status.activeProfile))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button(selected ? "使用中" : "启用智能档") { Task { await model.select(.smart) } }
                    .glassButtonStyle(prominent: !selected)
                    .tint(Palette.profile(.smart))
                    .disabled(selected)
                QuietFirstToggle(model: model, status: status).controlSize(.small)
            }
        }
        .padding(20)
        .glassCard(tint: selected ? Palette.profile(.smart).opacity(0.14) : nil)
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("始终生效的保护", symbol: "checkmark.shield")
            Group {
                Text("• 温度达到紧急阈值或系统热压力“危急”时风扇满速")
                Text("• 图书馆/安静档在过热或热压力“较高”时自动放开封顶，交还系统")
                Text("• 读不到可信温度、睡眠前、退出或卸载时，风扇交还系统")
                Text("• 转速永远限制在本机风扇的最小与最大转速之间")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassCard()
    }
}

private struct ProfileCard: View {
    let profile: FanProfile
    let fans: [FanStatus]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: profile.symbolName)
                        .font(.title2)
                        .foregroundStyle(Palette.profile(profile))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Palette.profile(profile))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(profile.displayName).font(.headline)
                Text(profile.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(profile.strategyDetail(for: fans))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .padding(18)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassCard(tint: selected ? Palette.profile(profile).opacity(0.18) : nil, interactive: true)
        .animation(.smooth, value: selected)
        .accessibilityLabel(profile.displayName)
        .accessibilityHint(profile.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
