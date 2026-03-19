import AppKit
import SwiftUI
import UserNotifications

@main
struct SpoolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        _ = AppModel.shared
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.settings.preloadSecretsForLaunch()
        model.appShell.start()
        model.recordingController.refreshStartupState()
        Task { @MainActor in
            await model.recordingController.warmUpPermissionsOnLaunch()
            if model.settings.outputRootPath.isEmpty {
                model.windowCoordinator.showSettings()
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.recordingController.refreshStartupState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.windowCoordinator.showSettings()
        }
        return true
    }
}
