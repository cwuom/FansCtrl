import FanCore
import SwiftUI

/// 一键整理：先列出每一步会做什么，用户勾选并确认后才执行。
struct CleanupCard: View {
    let monitor: ResourceMonitor
    @State private var closeFinder = true
    @State private var quitIDs: Set<String> = []
    @State private var endOrphans = true
    @State private var confirm = false
    @State private var initialized = false

    /// 退出后会影响正在进行的事（播放、收发消息）的应用默认不勾选
    private static let keepByDefault: Set<String> = [
        "com.apple.Music", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Podcasts",
        "com.spotify.client", "com.tencent.xinWeChat", "com.tencent.qq",
    ]

    /// 没有窗口、不在使用、不受保护的普通应用
    private var windowless: [ProcessGroup] {
        monitor.groups.filter { $0.isApp && $0.windowCount == 0 && !$0.isFrontmost && $0.protection == nil }
            .sorted { $0.footprint > $1.footprint }
    }

    private var orphans: [ProcessGroup] {
        monitor.groups.filter { $0.anomalies.contains(.orphanedHelpers) && $0.protection == nil }
    }

    private var plannedQuits: [ProcessGroup] { windowless.filter { quitIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("一键整理", symbol: "wand.and.sparkles")
            Text("长时间不关机时定期整理一次，可以回收内存、减少后台干扰。执行前会再次确认。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $closeFinder) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("关闭所有访达窗口")
                    Text("不退出访达，桌面和文件不受影响").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("退出没有窗口的应用（\(plannedQuits.count)/\(windowless.count)）")
                if windowless.isEmpty {
                    Text("没有无窗口的应用").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowChips(items: windowless, selected: $quitIDs)
                    Text("播放音乐、收发消息类应用默认不勾选").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Toggle(isOn: $endOrphans) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("结束主程序已退出的后台进程（\(orphans.count)）")
                    Text(orphans.isEmpty ? "没有发现" : orphans.map(\.name).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .disabled(orphans.isEmpty)

            HStack {
                Spacer()
                Button {
                    confirm = true
                } label: {
                    Label("立即整理", systemImage: "wand.and.sparkles")
                }
                .glassButtonStyle(prominent: true)
                .tint(.teal)
                .disabled(!closeFinder && plannedQuits.isEmpty && (!endOrphans || orphans.isEmpty))
            }
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard()
        .confirmationDialog("执行一键整理？", isPresented: $confirm) {
            Button("整理") { run() }
        } message: {
            Text(summary)
        }
        .onChange(of: windowless.map(\.id)) { _, ids in
            // 首次拿到列表时按规则预选；之后保留用户的勾选，只移除已消失的项
            if !initialized, !ids.isEmpty {
                quitIDs = Set(windowless.filter { g in
                    !(g.bundleID.map(Self.keepByDefault.contains) ?? false) && g.footprint >= 200 * 1_048_576
                }.map(\.id))
                initialized = true
            } else {
                quitIDs.formIntersection(ids)
            }
        }
    }

    private var summary: String {
        var lines: [String] = []
        if closeFinder { lines.append("• 关闭所有访达窗口") }
        if !plannedQuits.isEmpty { lines.append("• 退出：" + plannedQuits.map(\.name).joined(separator: "、")) }
        if endOrphans, !orphans.isEmpty { lines.append("• 结束后台进程：" + orphans.map(\.name).joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }

    private func run() {
        var done: [String] = []
        var problems: [String] = []
        if closeFinder {
            switch monitor.closeFinderWindows() {
            case .success: done.append("已关闭访达窗口")
            case .failure(let e): problems.append("\(e)")
            }
        }
        let quit = plannedQuits.filter { monitor.end($0, mode: .graceful) }
        if !quit.isEmpty { done.append("已请求退出 \(quit.count) 个应用") }
        if endOrphans {
            let ended = orphans.filter { monitor.end($0, mode: .graceful) }
            if !ended.isEmpty { done.append("已结束 \(ended.count) 组后台进程") }
        }
        monitor.message = (done + problems).joined(separator: "；")
        Task { await monitor.sampleOnce() }
    }
}

/// 可勾选的应用胶囊，自动换行
private struct FlowChips: View {
    let items: [ProcessGroup]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { g in
                let on = selected.contains(g.id)
                Button {
                    if on { selected.remove(g.id) } else { selected.insert(g.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Color.teal : Color.secondary)
                        AppIcon(path: g.bundlePath, size: 16)
                        Text(g.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ByteFormat.string(g.footprint)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(on ? Color.teal.opacity(0.14) : Color.primary.opacity(0.04)))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityLabel("\(g.name)，\(ByteFormat.string(g.footprint))")
            }
        }
    }
}
