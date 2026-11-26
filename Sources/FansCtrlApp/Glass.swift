import FanCore
import SwiftUI

/// Liquid Glass 只在 macOS 26+ 提供；更早的系统退回原生 Material，界面结构保持一致。
extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.fill(tint ?? .clear).allowsHitTesting(false))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: Capsule())
        } else {
            background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// 把相邻的玻璃元素放进同一容器，macOS 26 上它们会像液体一样融合、互相折射。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 主窗口背景：随温度变色的柔和网格渐变，给玻璃提供可折射的内容。
struct AmbientBackground: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base = Color(nsColor: .windowBackgroundColor)
        let strength = scheme == .dark ? 0.30 : 0.20
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: [
                base, tint.opacity(strength), base,
                Color.indigo.opacity(strength * 0.8), base, tint.opacity(strength * 0.6),
                base, Color.teal.opacity(strength * 0.7), base,
            ]
        )
        .ignoresSafeArea()
        .animation(.smooth(duration: 1.2), value: tint)
        .accessibilityHidden(true)
    }
}

/// 集中管理语义配色，避免各视图各写各的颜色。
enum Palette {
    static func temperature(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        switch t {
        case ..<70: return .mint
        case ..<90: return .orange
        default: return .red
        }
    }

    static func profile(_ p: FanProfile) -> Color {
        switch p {
        case .system: return .gray
        case .library: return .teal
        case .quiet: return .indigo
        case .balanced: return .blue
        case .performance: return .orange
        case .max: return .red
        case .smart: return .cyan
        }
    }

    static func state(_ s: ControlState) -> Color {
        switch s {
        case .system, .manual, .capped, .paused: return .secondary
        case .released, .sensorFault, .unsupported: return .orange
        case .emergency: return .red
        }
    }

    static let cpu = Color.orange
    static let gpu = Color.cyan
    static let fan = Color.mint
}
