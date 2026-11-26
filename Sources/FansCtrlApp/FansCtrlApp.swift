import AppKit
import FanCore
import SwiftUI

enum AppPreferences {
    static let showWindowOnLaunch = "showWindowOnLaunch"
}

@main
struct FansCtrlApp: App {
    @State private var model = StatusModel()
    @State private var resources = ResourceMonitor()
    @AppStorage(AppPreferences.showWindowOnLaunch) private var showWindowOnLaunch = true

    var body: some Scene {
        Window("FansCtrl", id: MainWindow.id) {
            MainWindow(model: model, resources: resources)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(showWindowOnLaunch ? .presented : .suppressed)

        MenuBarExtra {
            PanelView(model: model, resources: resources)
        } label: {
            // 强力压制期间在菜单栏直接显示倒计时，面板收起也能看到
            HStack(spacing: 3) {
                Image(systemName: model.suppressCountdown == nil
                      ? (model.status?.selectedProfile.symbolName ?? "fan")
                      : ControlState.suppressed.symbolName)
                if let left = model.suppressCountdown {
                    Text("\(left)s").monospacedDigit()
                }
            }
            .accessibilityLabel(model.suppressCountdown.map { "FansCtrl 强力压制中，剩余 \($0) 秒" } ?? "FansCtrl 风扇控制")
            .task { await model.refresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
