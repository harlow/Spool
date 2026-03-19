import Foundation

@main
struct GoogleCalendarSmokeTests {
    static func main() {
        do {
            try testAuthorizationURL()
            try testEventMatching()
            try testAgendaBucketing()
            try testEventDecoding()
            print("Google calendar smoke tests: PASS")
        } catch {
            fputs("Google calendar smoke tests: FAIL - \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testAuthorizationURL() throws {
        let url = GoogleCalendarService.authorizationURL(
            clientID: "client-id.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:8080/oauth2callback",
            codeChallenge: "challenge",
            state: "state-123"
        )
        let components = try require(URLComponents(url: url, resolvingAgainstBaseURL: false), "Missing URL components")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try assert(items["client_id"] == "client-id.apps.googleusercontent.com", "client_id missing from authorization URL")
        try assert(items["redirect_uri"] == "http://127.0.0.1:8080/oauth2callback", "redirect URI missing from authorization URL")
        try assert(items["code_challenge_method"] == "S256", "PKCE method missing")
        try assert((items["scope"] ?? "").contains("calendar.readonly"), "calendar scope missing")
    }

    private static func testEventMatching() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let active = makeEvent(id: "active", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(900))
        let soon = makeEvent(id: "soon", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800))
        let later = makeEvent(id: "later", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000))

        try assert(
            GoogleCalendarService.matchRecordingEvent(from: [soon, later, active], at: now)?.id == "active",
            "Expected active event to be preferred"
        )
    }

    private static func testAgendaBucketing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let current = makeEvent(id: "current", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1200))
        let soon = makeEvent(id: "soon", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600))
        let today = makeEvent(id: "today", start: now.addingTimeInterval(10800), end: now.addingTimeInterval(12600))
        let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
        let tomorrow = makeEvent(id: "tomorrow", start: tomorrowStart, end: tomorrowStart.addingTimeInterval(1800))

        let buckets = CalendarAgendaSnapshot.makeBuckets(from: [current, soon, today, tomorrow], now: now)
        try assert(buckets.map(\.kind) == [.now, .startsSoon, .today, .tomorrow], "Unexpected agenda bucket order")
        try assert(buckets.first(where: { $0.kind == .startsSoon })?.events.first?.id == "soon", "Expected soon bucket to contain the imminent event")
    }

    private static func testEventDecoding() throws {
        let json = """
        {
          "id": "evt-1",
          "status": "confirmed",
          "summary": "Intent Criteria Sync",
          "htmlLink": "https://calendar.google.com/calendar/event?eid=123",
          "hangoutLink": "https://meet.google.com/abc-defg-hij",
          "start": { "dateTime": "2026-03-18T10:45:00-07:00" },
          "end": { "dateTime": "2026-03-18T11:30:00-07:00" },
          "attendees": [
            { "displayName": "Harlow", "email": "harlow@example.com", "responseStatus": "accepted", "self": true },
            { "displayName": "Tracy", "email": "tracy@example.com", "responseStatus": "accepted" }
          ]
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        let agendaEvent = try require(
            GoogleCalendarService.makeAgendaEvent(from: event, calendarID: "primary", calendarName: "Work"),
            "Expected decoded event"
        )

        try assert(agendaEvent.title == "Intent Criteria Sync", "Event title decoding failed")
        try assert(agendaEvent.meetingURL?.absoluteString == "https://meet.google.com/abc-defg-hij", "Meeting URL selection failed")
        try assert(agendaEvent.attendees.count == 2, "Attendee decoding failed")
    }

    private static func makeEvent(id: String, start: Date, end: Date) -> CalendarAgendaEvent {
        CalendarAgendaEvent(
            id: id,
            title: id,
            startAt: start,
            endAt: end,
            isAllDay: false,
            attendees: [],
            eventURL: nil,
            meetingURL: nil,
            calendarID: "primary",
            calendarName: "Work"
        )
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeTestError(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeTestError(message) }
        return value
    }
}

struct SmokeTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
