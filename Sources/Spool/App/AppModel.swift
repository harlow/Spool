import Foundation

@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let calendarService: GoogleCalendarService
    let recordingController: RecordingController
    let meetingReminderService: MeetingReminderService
    let recordingIndicatorManager: RecordingIndicatorManager
    let windowCoordinator: WindowCoordinator
    let appShell: AppShell

    private init() {
        let settings = AppSettings()
        let calendarService = GoogleCalendarService(settings: settings)
        let recordingController = RecordingController(settings: settings, calendarService: calendarService)
        let meetingReminderService = MeetingReminderService(
            settings: settings,
            calendarService: calendarService,
            recordingController: recordingController
        )
        let recordingIndicatorManager = RecordingIndicatorManager()
        let windowCoordinator = WindowCoordinator(
            settings: settings,
            recordingController: recordingController,
            calendarService: calendarService,
            meetingReminderService: meetingReminderService
        )
        let appShell = AppShell(
            settings: settings,
            recordingController: recordingController,
            windowCoordinator: windowCoordinator,
            calendarService: calendarService,
            recordingIndicatorManager: recordingIndicatorManager
        )

        recordingController.onSetupRequired = { [weak windowCoordinator] in
            windowCoordinator?.showSettings()
        }

        self.settings = settings
        self.calendarService = calendarService
        self.recordingController = recordingController
        self.meetingReminderService = meetingReminderService
        self.recordingIndicatorManager = recordingIndicatorManager
        self.windowCoordinator = windowCoordinator
        self.appShell = appShell
    }
}
