import AppKit
import FanCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, resources, profiles, service, about

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .resources: return "资源"
        case .profiles: return "档位"
        case .service: return "设置"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .resources: return "memorychip"
        case .profiles: return "dial.high"
        case .service: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct MainWindow: View {
    static let id = "main"

    let model: StatusModel
    let resources: ResourceMonitor
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
                if section == .service {
                    // 原生 Form 自带滚动和内边距，不再外套 ScrollView，避免顶部双重留白
                    VStack(spacing: 0) {
                        ServiceUpdateBanner(model: model).padding([.horizontal, .top], 20)
                        ServiceView(model: model)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ServiceUpdateBanner(model: model)
                            detail
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 920, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            // 工具栏透明，让背景渐变延伸到标题栏下方，内容滚动时由系统做边缘渐隐
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let s = model.status { StateChip(state: s.state, countdown: model.suppressCountdown) }
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
        case .resources:
            ResourcesView(monitor: resources)
        case .profiles:
            ConnectionGate(model: model) { ProfilesView(model: model, status: $0) }
        case .service:
            EmptyView()
        case .about:
            AboutView()
        }
    }
}
