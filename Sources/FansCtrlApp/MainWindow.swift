import AppKit
import FanCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, profiles, service, about

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .profiles: return "档位"
        case .service: return "设置"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .profiles: return "dial.high"
        case .service: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct MainWindow: View {
    static let id = "main"

    let model: StatusModel
    @SceneStorage("mainSection") private var section: MainSection = .overview

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: Binding(get: { section }, set: { section = $0 ?? .overview })) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ZStack {
                AmbientBackground(tint: Palette.temperature(model.status?.controlTemp))
                ScrollView {
                    detail
                        .padding(24)
                        .frame(maxWidth: 920, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let s = model.status { StateChip(state: s.state) }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            model.beginObserving()
            // 主窗口打开时显示 Dock 图标，关闭后只保留菜单栏图标
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
        .onDisappear {
            model.endObserving()
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview:
            ConnectionGate(model: model) { OverviewView(model: model, status: $0) }
        case .profiles:
            ConnectionGate(model: model) { ProfilesView(model: model, status: $0) }
        case .service:
            ServiceView(model: model)
        case .about:
            AboutView()
        }
    }
}
