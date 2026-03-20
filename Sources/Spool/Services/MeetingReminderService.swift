import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

@Observable
@MainActor
final class MeetingReminderService: NSObject, UNUserNotificationCenterDelegate {
    private let settings: AppSettings
    private let calendarService: GoogleCalendarService
    private let recordingController: RecordingController
    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?
    private var notifiedEventIDs: Set<String> = []
    private var hasStarted = false

    var notificationsAuthorized = false
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    private let leadTime: TimeInterval = 2 * 60

    init(settings: AppSettings, calendarService: GoogleCalendarService, recordingController: RecordingController) {
        self.settings = settings
        self.calendarService = calendarService
        self.recordingController = recordingController
    }

    var notificationAccessLabel: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional:
            return "Allowed"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        @unknown default:
            return "Unknown"
        }
    }

    var statusLine: String {
        if !settings.calendarIntegrationEnabled {
            return "Enable Google Calendar integration to schedule reminders."
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional:
            break
        case .notDetermined:
            return "Notification permission will be requested when a reminder is due."
        case .denied:
            return "Notifications are denied for Spool."
        @unknown default:
            return "Notification authorization state is unavailable."
        }

        guard let event = nextImminentEvent() else {
            return "No join reminders due in the next two minutes."
        }

        return "Next reminder: \(event.title) at \(Self.timeText(for: event.startAt))"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        center.delegate = self
        center.setNotificationCategories([Self.makeMeetingCategory()])

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAndNotifyIfNeeded()
            }
        }

        Task { @MainActor in
            await refreshAndNotifyIfNeeded(forceAgendaRefresh: true)
        }
    }

    func refreshNow() async {
        await refreshAuthorizationStatus()
        await refreshAndNotifyIfNeeded(forceAgendaRefresh: true)
    }

    func requestAuthorizationNow() async {
        settings.didReviewNotificationAccess = true
        _ = await requestAuthorization(forcePrompt: true)
    }

    func sendTestNotification() async {
        settings.didReviewNotificationAccess = true
        let granted = await requestAuthorization(forcePrompt: true)
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Spool test reminder"
        content.body = "Join Meeting & record in Spool"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let request = UNNotificationRequest(
            identifier: "meeting-reminder-test",
            content: content,
            trigger: nil
        )
        _ = await addNotification(request)
    }

    func refreshAndNotifyIfNeeded(forceAgendaRefresh: Bool = false) async {
        guard settings.calendarIntegrationEnabled else { return }
        guard recordingController.state != .recording else { return }

        let shouldForceRefresh = forceAgendaRefresh || shouldForceUpcomingAgendaRefresh()
        await calendarService.refreshAgenda(force: shouldForceRefresh)
        pruneNotifiedEvents()

        guard let event = nextImminentEvent() else { return }
        let granted = await requestAuthorization(forcePrompt: false)
        guard granted else { return }
        let didDeliver = await deliverNotification(for: event)
        guard didDeliver else { return }
        notifiedEventIDs.insert(event.id)
    }

    private func requestAuthorization(forcePrompt: Bool) async -> Bool {
        await refreshAuthorizationStatus()

        switch notificationAuthorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard forcePrompt || nextImminentEvent() != nil else {
                return false
            }
            let granted = await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            await refreshAuthorizationStatus()
            notificationsAuthorized = granted
            return granted
        @unknown default:
            return false
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        notificationsAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func nextImminentEvent(now: Date = Date()) -> CalendarAgendaEvent? {
        let cutoff = now.addingTimeInterval(leadTime)
        return calendarService.agendaSnapshot?.allEvents
            .filter { event in
                event.primaryURL != nil &&
                event.startAt > now &&
                event.startAt <= cutoff &&
                !self.notifiedEventIDs.contains(event.id)
            }
            .sorted { $0.startAt < $1.startAt }
            .first
    }

    private func pruneNotifiedEvents(now: Date = Date()) {
        guard let events = calendarService.agendaSnapshot?.allEvents else {
            notifiedEventIDs.removeAll()
            return
        }

        let activeIDs = Set(events.filter { $0.endAt > now }.map(\.id))
        notifiedEventIDs = notifiedEventIDs.intersection(activeIDs)
    }

    private func shouldForceUpcomingAgendaRefresh(now: Date = Date()) -> Bool {
        guard let snapshot = calendarService.agendaSnapshot else { return true }
        guard let nextEvent = snapshot.allEvents
            .filter({ $0.startAt > now && $0.primaryURL != nil })
            .sorted(by: { $0.startAt < $1.startAt })
            .first else {
            return false
        }

        return nextEvent.startAt.timeIntervalSince(now) <= leadTime
    }

    private func deliverNotification(for event: CalendarAgendaEvent) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "\(Self.timeRangeText(for: event))\nJoin Meeting & record in Spool"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = Self.makeUserInfo(for: event)

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(for: event.id),
            content: content,
            trigger: nil
        )
        return await addNotification(request)
    }

    private func addNotification(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == Self.categoryIdentifier else { return }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == Self.joinActionIdentifier else {
            return
        }

        let userInfo = response.notification.request.content.userInfo
        await self.handleJoinAndRecord(userInfo: userInfo)
    }

    private func handleJoinAndRecord(userInfo: [AnyHashable: Any]) async {
        guard let event = Self.makeEvent(from: userInfo) else { return }

        if recordingController.canStartNewRecording {
            let didStart = await recordingController.startRecording(for: event)
            guard didStart else { return }
        }

        if let url = event.primaryURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func notificationIdentifier(for eventID: String) -> String {
        "meeting-reminder-\(eventID)"
    }

    private static func timeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private static func timeRangeText(for event: CalendarAgendaEvent) -> String {
        if event.isAllDay {
            return "All day"
        }

        return "\(timeText(for: event.startAt)) - \(timeText(for: event.endAt))"
    }

    private static func makeUserInfo(for event: CalendarAgendaEvent) -> [String: Any] {
        [
            "id": event.id,
            "title": event.title,
            "startAt": event.startAt.timeIntervalSince1970,
            "endAt": event.endAt.timeIntervalSince1970,
            "isAllDay": event.isAllDay,
            "calendarID": event.calendarID,
            "calendarName": event.calendarName,
            "eventURL": event.eventURL?.absoluteString ?? "",
            "meetingURL": event.meetingURL?.absoluteString ?? ""
        ]
    }

    private static func makeEvent(from userInfo: [AnyHashable: Any]) -> CalendarAgendaEvent? {
        guard
            let id = userInfo["id"] as? String,
            let title = userInfo["title"] as? String,
            let startAt = userInfo["startAt"] as? TimeInterval,
            let endAt = userInfo["endAt"] as? TimeInterval,
            let isAllDay = userInfo["isAllDay"] as? Bool,
            let calendarID = userInfo["calendarID"] as? String,
            let calendarName = userInfo["calendarName"] as? String
        else {
            return nil
        }

        let eventURLString = userInfo["eventURL"] as? String
        let meetingURLString = userInfo["meetingURL"] as? String

        return CalendarAgendaEvent(
            id: id,
            title: title,
            startAt: Date(timeIntervalSince1970: startAt),
            endAt: Date(timeIntervalSince1970: endAt),
            isAllDay: isAllDay,
            attendees: [],
            eventURL: eventURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            meetingURL: meetingURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            calendarID: calendarID,
            calendarName: calendarName
        )
    }

    nonisolated private static let categoryIdentifier = "SPOOL_MEETING_REMINDER"
    nonisolated private static let joinActionIdentifier = "JOIN_AND_RECORD"

    @MainActor
    private static func makeMeetingCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: joinActionIdentifier,
                    title: "Join Meeting & record in Spool",
                    options: [.foreground]
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}
