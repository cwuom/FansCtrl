import AppKit
import SwiftUI

/// MenuBarExtra 的窗口在内容变高后会跟着变高，但内容变矮时不会缩回，
/// 多出的高度被平均分到上下，形成留白。这里测量内容高度，主动把窗口缩到内容高度并保持顶边不动。
private struct PanelWindowSizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = height
        DispatchQueue.main.async {
            guard target > 0, let window = view.window else { return }
            var frame = window.frame
            let contentHeight = window.contentRect(forFrameRect: frame).height
            let delta = target - contentHeight
            guard abs(delta) > 0.5 else { return }
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

extension View {
    /// 让所在窗口的高度始终等于该视图的理想高度
    func sizesWindowToContent() -> some View {
        modifier(SizesWindowToContent())
    }
}

private struct SizesWindowToContent: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // 让视图报告自身理想高度，而不是被窗口撑满
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .background(PanelWindowSizer(height: height))
    }
}
