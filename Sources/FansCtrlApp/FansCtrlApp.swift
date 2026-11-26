import AppKit
import FanCore
import SwiftUI

enum AppPreferences {
    static let showWindowOnLaunch = "showWindowOnLaunch"
}

@main
struct FansCtrlApp: App {
    @State private var model = StatusModel()
    @AppStorage(AppPreferences.showWindowOnLaunch) private var showWindowOnLaunch = true

    var body: some Scene {
        Window("FansCtrl", id: MainWindow.id) {
            MainWindow(model: model)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(showWindowOnLaunch ? .presented : .suppressed)

        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.status?.selectedProfile.symbolName ?? "fan")
                .accessibilityLabel("FansCtrl 风扇控制")
                .task { await model.refresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
