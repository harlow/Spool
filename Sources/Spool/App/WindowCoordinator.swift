import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let recordingController: RecordingController
    private let calendarService: GoogleCalendarService
    private let meetingReminderService: MeetingReminderService

    private var settingsWindow: NSWindow?

    init(
        settings: AppSettings,
        recordingController: RecordingController,
        calendarService: GoogleCalendarService,
        meetingReminderService: MeetingReminderService
    ) {
        self.settings = settings
        self.recordingController = recordingController
        self.calendarService = calendarService
        self.meetingReminderService = meetingReminderService
        super.init()
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Spool Settings",
            content: SettingsView(
                settings: settings,
                recordingController: recordingController,
                calendarService: calendarService,
                meetingReminderService: meetingReminderService
            )
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
        window.delegate = self
        return window
    }

    private func show(_ window: NSWindow) {
        updateActivationPolicy(hasVisibleWindow: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible }
            updateActivationPolicy(hasVisibleWindow: hasVisibleWindow)
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        updateActivationPolicy(hasVisibleWindow: true)
    }

    private func updateActivationPolicy(hasVisibleWindow: Bool) {
        let desiredPolicy: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }
}
