import AppKit
import FanCore
import SwiftUI

struct ResourcesView: View {
    let monitor: ResourceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = monitor.resources {
                ResourceMetricsRow(resources: r)
            }
            if !monitor.health.isEmpty {
                HealthIssuesCard(issues: monitor.health)
            }
            RecommendationsCard(monitor: monitor)
            CleanupCard(monitor: monitor)
            ProcessTableCard(monitor: monitor)
            if let m = monitor.message { NoticeRow(text: m, tint: .blue) }
        }
        .onAppear { monitor.begin(.full) }
        .onDisappear { monitor.end(.full) }
    }
}

// MARK: - 资源概况

struct ResourceMetricsRow: View {
    let resources: ResourceSnapshot

    var body: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if let m = resources.memory {
                    MetricTile(title: "可用内存", value: ByteFormat.string(m.available),
                               detail: "共 \(ByteFormat.string(m.total)) · 压力\(m.pressure.displayName)",
                               fraction: Double(m.used) / Double(max(m.total, 1)), tint: pressureColor(m.pressure),
                               symbol: "memorychip")
                    MetricTile(title: "交换已用", value: ByteFormat.string(m.swapUsed),
                               detail: m.swapUsed == 0 ? "未使用交换空间" : "压缩 \(ByteFormat.string(m.compressed))",
                               fraction: nil, tint: m.swapUsed > m.total / 4 ? .orange : .teal, symbol: "arrow.left.arrow.right")
                }
                if let d = resources.disk {
                    MetricTile(title: "磁盘可用", value: ByteFormat.string(d.available),
                               detail: "共 \(ByteFormat.string(d.total))",
                               fraction: 1 - d.availableFraction, tint: d.availableFraction < 0.1 ? .orange : .blue,
                               symbol: "internaldrive")
                }
                if let up = resources.uptime {
                    MetricTile(title: "已运行", value: Self.uptimeText(up), detail: "自上次开机",
                               fraction: nil, tint: up > 7 * 86_400 ? .orange : .mint, symbol: "clock")
                }
            }
        }
    }

    static func uptimeText(_ t: TimeInterval) -> String {
        let days = Int(t / 86_400), hours = Int(t.truncatingRemainder(dividingBy: 86_400) / 3600)
        return days > 0 ? "\(days) 天 \(hours) 时" : "\(hours) 小时 \(Int(t.truncatingRemainder(dividingBy: 3600) / 60)) 分"
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?
    let tint: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let f = fraction {
                ProgressView(value: min(max(f, 0), 1)).tint(tint)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 16, tint: tint.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

private struct HealthIssuesCard: View {
    let issues: [HealthIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("长时间运行体检", symbol: "stethoscope")
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(issue.severity))
                        .foregroundStyle(color(issue.severity))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.callout.weight(.semibold))
                        Text(issue.advice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard(tint: color(issues.first?.severity ?? .info).opacity(0.08))
    }

    private func icon(_ s: HealthIssue.Severity) -> String {
        switch s {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func color(_ s: HealthIssue.Severity) -> Color {
        switch s {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - 建议处理

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "gearshape.2").resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct RecommendationsCard: View {
    let monitor: ResourceMonitor
    @State private var selected: Set<String> = []
    @State private var confirm = false

    private var items: [ProcessGroup] { monitor.recommendations }
    private var chosen: [ProcessGroup] { items.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle("建议处理", symbol: "sparkles")
                Spacer()
                if !items.isEmpty {
                    Button("结束所选（\(chosen.count)）") { confirm = true }
                        .glassButtonStyle(prominent: !chosen.isEmpty)
                        .tint(.orange)
                        .disabled(chosen.isEmpty)
                }
            }
            if items.isEmpty {
                Label(monitor.groups.isEmpty ? "正在分析进程…" : "没有发现异常进程，系统状态良好",
                      systemImage: monitor.groups.isEmpty ? "hourglass" : "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(monitor.groups.isEmpty ? Color.secondary : Color.green)
                    .padding(.vertical, 6)
            } else {
                Text("根据持续占用、增长趋势和是否在使用综合排序。普通应用会正常退出（未保存的文档会提示保存）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(items) { g in
                    RecommendationRow(group: g, isOn: Binding(
                        get: { selected.contains(g.id) },
                        set: { on in if on { selected.insert(g.id) } else { selected.remove(g.id) } }
                    )) {
                        monitor.end(g, mode: .graceful)
                        selected.remove(g.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard()
        .confirmationDialog("结束 \(chosen.count) 个应用/进程？", isPresented: $confirm) {
            Button("结束", role: .destructive) {
                let ended = chosen.filter { monitor.end($0, mode: .graceful) }
                monitor.message = "已请求结束：\(ended.map(\.name).joined(separator: "、"))"
                selected.removeAll()
            }
        } message: {
            Text(chosen.map(\.name).joined(separator: "、") + "\n普通应用会正常退出，可能会先询问是否保存。")
        }
        .onChange(of: items.map(\.id)) { _, ids in selected.formIntersection(ids) }
    }
}

private struct RecommendationRow: View {
    let group: ProcessGroup
    @Binding var isOn: Bool
    let onEnd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("选择 \(group.name)")
            AppIcon(path: group.bundlePath, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name).font(.callout.weight(.semibold))
                    ForEach(group.anomalies, id: \.self) { a in
                        Text(a.title)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(group.anomalies.first?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%% CPU", group.cpuPercent)).font(.caption.monospacedDigit())
                Text(ByteFormat.string(group.footprint)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(group.isApp ? "退出" : "结束", action: onEnd)
                .glassButtonStyle(prominent: false)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
    }
}

// MARK: - 全部进程

private struct ProcessTableCard: View {
    let monitor: ResourceMonitor
    @State private var sortOrder = [KeyPathComparator(\ProcessGroup.cpuPercent, order: .reverse)]
    @State private var search = ""
    @State private var forceTarget: ProcessGroup?

    private var rows: [ProcessGroup] {
        let filtered = search.isEmpty ? monitor.groups
            : monitor.groups.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle("全部应用与进程", symbol: "list.bullet.rectangle")
                Text("\(monitor.groups.count) 组 · 辅助进程已归入所属应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("搜索", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { g in
                    HStack(spacing: 8) {
                        AppIcon(path: g.bundlePath, size: 18)
                        Text(g.name).lineLimit(1)
                        if g.pids.count > 1 {
                            Text("\(g.pids.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 200, ideal: 260)
                TableColumn("CPU", value: \.cpuPercent) { g in
                    Text(String(format: "%.1f%%", g.cpuPercent)).monospacedDigit()
                }
                .width(70)
                TableColumn("内存", value: \.footprint) { g in
                    Text(ByteFormat.string(g.footprint)).monospacedDigit()
                }
                .width(80)
                TableColumn("状态") { g in
                    Text(status(of: g))
                        .foregroundStyle(g.isRecommended ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 380)
            .contextMenu(forSelectionType: ProcessGroup.ID.self) { ids in
                if let id = ids.first, let g = monitor.groups.first(where: { $0.id == id }) {
                    if g.protection == nil {
                        Button(g.isApp ? "退出" : "结束") { monitor.end(g, mode: .graceful) }
                        Button("强制结束…") { forceTarget = g }
                    }
                    if let path = g.bundlePath {
                        Button("在访达中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    }
                }
            }
        }
        .padding(18)
        .glassCard()
        .confirmationDialog("强制结束“\(forceTarget?.name ?? "")”？", isPresented: Binding(
            get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }
        )) {
            Button("强制结束", role: .destructive) {
                if let g = forceTarget { monitor.end(g, mode: .force) }
                forceTarget = nil
            }
        } message: {
            Text("强制结束不会保存任何未保存的内容。")
        }
    }

    private func status(of g: ProcessGroup) -> String {
        if let p = g.protection { return p.reason }
        if g.isFrontmost { return "正在使用" }
        if let a = g.anomalies.first { return a.title }
        return g.isApp ? (g.windowCount == 0 ? "无窗口" : "\(g.windowCount) 个窗口") : "后台进程"
    }
}
