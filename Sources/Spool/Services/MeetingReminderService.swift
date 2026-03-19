import AppKit
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class MeetingReminderService: NSObject, UNUserNotificationCenterDelegate {
    private let settings: AppSettings
    private let calendarService: GoogleCalendarService
    private let recordingController: RecordingController
    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?
    private var notifiedEventIDs: Set<String> = []
    private(set) var notificationsAuthorized = false

    private let leadTime: TimeInterval = 5 * 60

    init(settings: AppSettings, calendarService: GoogleCalendarService, recordingController: RecordingController) {
        self.settings = settings
        self.calendarService = calendarService
        self.recordingController = recordingController
    }

    func start() {
        center.delegate = self
        center.setNotificationCategories([Self.makeMeetingCategory()])
        requestAuthorization()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAndNotifyIfNeeded()
            }
        }

        Task { @MainActor in
            await refreshAndNotifyIfNeeded(forceAgendaRefresh: true)
        }
    }

    func refreshAndNotifyIfNeeded(forceAgendaRefresh: Bool = false) async {
        guard settings.calendarIntegrationEnabled else { return }
        guard recordingController.state != .recording else { return }

        let shouldForceRefresh = forceAgendaRefresh || shouldForceUpcomingAgendaRefresh()
        await calendarService.refreshAgenda(force: shouldForceRefresh)
        pruneNotifiedEvents()

        guard let event = nextImminentEvent() else { return }
        notifiedEventIDs.insert(event.id)
        deliverNotification(for: event)
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
            }
        }
        Task { @MainActor in
            await refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func nextImminentEvent(now: Date = Date()) -> CalendarAgendaEvent? {
        let cutoff = now.addingTimeInterval(leadTime)
        return calendarService.agendaSnapshot?.allEvents
            .filter { event in
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
            .filter({ $0.startAt > now })
            .sorted(by: { $0.startAt < $1.startAt })
            .first else {
            return false
        }

        return nextEvent.startAt.timeIntervalSince(now) <= leadTime
    }

    private func deliverNotification(for event: CalendarAgendaEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "\(Self.timeRangeText(for: event))\nJoin Meeting & Record with Spool"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = Self.makeUserInfo(for: event)

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(for: event.id),
            content: content,
            trigger: nil
        )
        center.add(request)
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

    private static func timeRangeText(for event: CalendarAgendaEvent) -> String {
        if event.isAllDay {
            return "All day"
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: event.startAt)) - \(formatter.string(from: event.endAt))"
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
                    title: "Join Meeting & Record with Spool"
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}
