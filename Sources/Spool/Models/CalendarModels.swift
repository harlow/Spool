import Foundation

package struct CalendarAttendee: Codable, Sendable, Equatable, Identifiable {
    package var id: String {
        email ?? displayName ?? "unknown-attendee-\(isSelf)"
    }

    package let displayName: String?
    package let email: String?
    package let responseStatus: String?
    package let isSelf: Bool

    package init(displayName: String?, email: String?, responseStatus: String?, isSelf: Bool) {
        self.displayName = displayName
        self.email = email
        self.responseStatus = responseStatus
        self.isSelf = isSelf
    }

    var label: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let email, !email.isEmpty {
            return email
        }
        return "Unknown attendee"
    }
}

struct CallContext: Codable, Sendable, Equatable {
    let eventID: String
    let eventTitle: String
    let startAt: Date
    let endAt: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarName: String
    let attendees: [CalendarAttendee]
    let eventURL: URL?
    let meetingURL: URL?
}

package struct CalendarAgendaEvent: Codable, Sendable, Equatable, Identifiable {
    package let id: String
    package let title: String
    package let startAt: Date
    package let endAt: Date
    package let isAllDay: Bool
    package let attendees: [CalendarAttendee]
    package let eventURL: URL?
    package let meetingURL: URL?
    package let calendarID: String
    package let calendarName: String

    package init(
        id: String,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool,
        attendees: [CalendarAttendee],
        eventURL: URL?,
        meetingURL: URL?,
        calendarID: String,
        calendarName: String
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.eventURL = eventURL
        self.meetingURL = meetingURL
        self.calendarID = calendarID
        self.calendarName = calendarName
    }

    var primaryURL: URL? {
        meetingURL ?? eventURL
    }

    func makeCallContext() -> CallContext {
        CallContext(
            eventID: id,
            eventTitle: title,
            startAt: startAt,
            endAt: endAt,
            isAllDay: isAllDay,
            calendarID: calendarID,
            calendarName: calendarName,
            attendees: attendees,
            eventURL: eventURL,
            meetingURL: meetingURL
        )
    }
}

struct CalendarListItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let isPrimary: Bool
}

package enum CalendarAgendaBucketKind: String, Codable, Sendable, Equatable, CaseIterable {
    case now
    case startsSoon
    case today
    case tomorrow

    func title(relativeTo now: Date, referenceEvent: CalendarAgendaEvent?) -> String {
        switch self {
        case .now:
            return "Now"
        case .startsSoon:
            guard let referenceEvent else { return "Upcoming" }
            return "Upcoming \(makeRelativeFormatter().localizedString(for: referenceEvent.startAt, relativeTo: now))"
        case .today:
            return "Today"
        case .tomorrow:
            return "Tomorrow"
        }
    }

    private func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }
}

package struct CalendarAgendaBucket: Codable, Sendable, Equatable, Identifiable {
    package let kind: CalendarAgendaBucketKind
    package let events: [CalendarAgendaEvent]
    package let referenceDate: Date

    package var id: String { kind.rawValue }

    package var title: String {
        kind.title(relativeTo: referenceDate, referenceEvent: events.first)
    }
}

package struct CalendarAgendaSnapshot: Codable, Sendable, Equatable {
    package let generatedAt: Date
    package let buckets: [CalendarAgendaBucket]
    package let allEvents: [CalendarAgendaEvent]
}

enum CalendarIntegrationStatus: Equatable, Sendable {
    case disabled
    case clientConfigurationRequired
    case authRequired
    case loading(String)
    case ready
    case error(String)

    var summaryText: String {
        switch self {
        case .disabled:
            return "Calendar integration is disabled."
        case .clientConfigurationRequired:
            return "Add a Google OAuth client ID to connect Google Calendar."
        case .authRequired:
            return "Google Calendar access is not connected yet."
        case .loading(let message):
            return message
        case .ready:
            return "Google Calendar is ready."
        case .error(let message):
            return message
        }
    }
}

extension CalendarAgendaSnapshot {
    package static func makeBuckets(from events: [CalendarAgendaEvent], now: Date, calendar: Calendar = .current) -> [CalendarAgendaBucket] {
        let startsSoonCutoff = now.addingTimeInterval(90 * 60)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now

        let nowEvents = events.filter { $0.startAt <= now && $0.endAt > now }
        let nextSoonEvent = events
            .filter { $0.startAt > now && $0.startAt <= startsSoonCutoff }
            .sorted(by: { $0.startAt < $1.startAt })
            .first
        let todayEvents = events.filter {
            guard $0.startAt > now else { return false }
            guard calendar.isDate($0.startAt, inSameDayAs: now) else { return false }
            return $0.id != nextSoonEvent?.id
        }
        let tomorrowEvents = events.filter { calendar.isDate($0.startAt, inSameDayAs: tomorrow) }

        let buckets: [(CalendarAgendaBucketKind, [CalendarAgendaEvent])] = [
            (.now, nowEvents),
            (.startsSoon, nextSoonEvent.map { [$0] } ?? []),
            (.today, todayEvents),
            (.tomorrow, tomorrowEvents)
        ]

        return buckets.compactMap { kind, items in
            guard !items.isEmpty else { return nil }
            return CalendarAgendaBucket(kind: kind, events: items, referenceDate: now)
        }
    }
}
