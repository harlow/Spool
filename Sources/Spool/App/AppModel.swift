import Foundation

@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let calendarService: GoogleCalendarService
    let recordingController: RecordingController
    let meetingReminderService: MeetingReminderService
    let adHocMeetingDetector: AdHocMeetingDetector
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
        let adHocMeetingDetector = AdHocMeetingDetector(
            settings: settings,
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

        // Wire ad-hoc detection → notification delivery
        adHocMeetingDetector.onMeetingDetected = { [weak meetingReminderService] app in
            Task { @MainActor in
                await meetingReminderService?.deliverAdHocNotification(appName: app?.name)
            }
        }
        adHocMeetingDetector.onMeetingEnded = { [weak meetingReminderService] in
            meetingReminderService?.cancelAdHocNotification()
        }

        // Wire notification actions → recording / suppression
        meetingReminderService.onAdHocAccepted = { [weak recordingController, weak adHocMeetingDetector] in
            adHocMeetingDetector?.resetDetection()
            Task { @MainActor in
                await recordingController?.startPlainRecording()
            }
        }
        meetingReminderService.onAdHocNotAMeeting = { [weak adHocMeetingDetector] in
            adHocMeetingDetector?.suppressCurrentApp()
        }

        self.settings = settings
        self.calendarService = calendarService
        self.recordingController = recordingController
        self.meetingReminderService = meetingReminderService
        self.adHocMeetingDetector = adHocMeetingDetector
        self.recordingIndicatorManager = recordingIndicatorManager
        self.windowCoordinator = windowCoordinator
        self.appShell = appShell

        // Migrate secrets from the legacy single-item Keychain envelope
        // into individual items.  After this, every KeychainHelper.load()
        // resolves on the first lookup — no second prompt for the envelope.
        KeychainHelper.migrateLegacyEnvelopeIfNeeded()

        // Preload Keychain items so later reads use cached values.
        settings.loadSummaryAPIKeyIfNeeded()
        calendarService.loadRefreshTokenIfNeeded()
    }
}
