import FanCore
import SwiftUI

/// 菜单栏面板：快速查看与切档。
struct PanelView: View {
    let model: StatusModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ConnectionGate(model: model) { s in
                PanelHero(status: s)
                PanelProfiles(model: model, status: s)
                if let note = s.lastError { NoticeRow(text: note) }
            }
            if let m = model.message { NoticeRow(text: m, tint: .blue) }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { model.beginObserving() }
        .onDisappear { model.endObserving() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fan.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.rotate, isActive: (model.status?.fans.first?.actualRPM ?? 0) > 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("FansCtrl").font(.headline)
                Text(model.status?.model ?? "风扇控制").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = model.status { StateChip(state: s.state) }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: MainWindow.id)
                NSApplication.shared.activate()
            } label: {
                Label("打开主界面", systemImage: "macwindow")
            }
            .glassButtonStyle(prominent: false)
            .controlSize(.small)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .glassButtonStyle(prominent: false)
                .controlSize(.small)
        }
    }
}

private struct PanelHero: View {
    let status: StatusSnapshot

    var body: some View {
        HStack(spacing: 16) {
            TemperatureMetric(title: "CPU", value: status.cpuTemp)
            TemperatureMetric(title: "GPU", value: status.gpuTemp)
            Spacer(minLength: 0)
            ForEach(status.fans, id: \.index) { FanGauge(fan: $0) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .glassCard(tint: Palette.temperature(status.controlTemp).opacity(0.12))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: status.onBattery ? "battery.75percent" : "powerplug.portrait")
                Text(status.cpuLoad.map { "负载 \(Int($0 * 100))%" } ?? "负载 --")
                Text("· 热压力 \(status.thermal.displayName)")
                if status.dryRun { Text("· 演示模式") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct PanelProfiles: View {
    let model: StatusModel
    let status: StatusSnapshot

    private let grid: [FanProfile] = [.library, .quiet, .balanced, .performance, .max, .system]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private var smartSelected: Bool { model.selectedProfile == .smart }

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.select(.smart) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: FanProfile.smart.symbolName).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("智能").font(.subheadline.weight(.semibold))
                                Text(smartSelected
                                     ? "当前：\(status.activeProfile.displayName) · \(status.smartReason ?? "")"
                                     : FanProfile.smart.summary)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .opacity(0.8)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .glassButtonStyle(prominent: smartSelected)
                    .tint(smartSelected ? Palette.profile(.smart) : nil)
                    .accessibilityLabel("智能档")
                    .accessibilityAddTraits(smartSelected ? .isSelected : [])

                    QuietFirstToggle(model: model, status: status)
                        .controlSize(.small)
                        .font(.caption)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(grid, id: \.self) { p in
                        ProfileTile(profile: p, selected: model.selectedProfile == p) {
                            Task { await model.select(p) }
                        }
                    }
                }
            }
        }
        if let p = model.selectedProfile, p != .smart {
            Text("\(p.summary) · \(p.strategyDetail(for: status.fans))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
