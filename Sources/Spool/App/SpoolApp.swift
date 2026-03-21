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
        UNUserNotificationCenter.current().delegate = model.meetingReminderService
        model.appShell.start()
        model.recordingController.refreshStartupState()
        Task { @MainActor in
            await model.meetingReminderService.refreshAuthorizationStatus()
            if model.windowCoordinator.shouldShowOnboarding() {
                model.windowCoordinator.showOnboarding()
            } else {
                model.meetingReminderService.start()
                model.adHocMeetingDetector.start()
                await model.calendarService.refreshStatus(force: false)
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.recordingController.refreshStartupState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if AppModel.shared.windowCoordinator.shouldShowOnboarding() {
                AppModel.shared.windowCoordinator.showOnboarding()
            } else {
                AppModel.shared.windowCoordinator.showSettings()
            }
        }
        return true
    }
}
