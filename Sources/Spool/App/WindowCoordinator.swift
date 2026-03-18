import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
    private let settings: AppSettings
    private let recordingController: RecordingController

    private var settingsWindow: NSWindow?

    init(settings: AppSettings, recordingController: RecordingController) {
        self.settings = settings
        self.recordingController = recordingController
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Spool Settings",
            content: SettingsView(settings: settings, recordingController: recordingController)
        )
        settingsWindow = window
        show(window)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    private func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
