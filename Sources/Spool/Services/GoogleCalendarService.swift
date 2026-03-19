import AppKit
import CryptoKit
import Foundation
import Network
import Observation

struct GoogleCalendarTokenSet: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresAt: Date
}

struct GoogleCalendarAccount: Codable, Sendable, Equatable {
    let email: String
    let name: String?
}

package struct GoogleCalendarAuthorizationRequest: Sendable, Equatable {
    let url: URL
    let verifier: String
    let state: String
    let redirectURI: String
}

struct GoogleCalendarHTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

@MainActor
@Observable
package final class GoogleCalendarService {
    typealias HTTPSender = @Sendable (URLRequest) async throws -> GoogleCalendarHTTPResult
    typealias BrowserOpener = @Sendable (URL) -> Void

    private let settings: AppSettings
    private let sendRequest: HTTPSender
    private let openBrowser: BrowserOpener
    private let nowProvider: @Sendable () -> Date
    private let agendaTTL: TimeInterval = 60
    private var callbackServer: GoogleOAuthCallbackServer?
    private var pendingAuthorization: GoogleCalendarAuthorizationRequest?
    private var cachedTokens: GoogleCalendarTokenSet?
    private let logURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "Spool", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appending(path: "google-calendar.log")
    }()

    var integrationStatus: CalendarIntegrationStatus = .disabled
    var availableCalendars: [CalendarListItem] = []
    var agendaSnapshot: CalendarAgendaSnapshot?
    var lastNonBlockingError: String?
    var lastBlockingError: String?
    var connectedAccount: GoogleCalendarAccount?

    init(
        settings: AppSettings,
        sendRequest: @escaping HTTPSender = { request in try await GoogleCalendarService.liveHTTPSender(request) },
        openBrowser: @escaping BrowserOpener = { NSWorkspace.shared.open($0) },
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.sendRequest = sendRequest
        self.openBrowser = openBrowser
        self.nowProvider = nowProvider
    }

    func start() {
        Task { @MainActor in
            log("Calendar service start")
            await refreshStatus(force: false)
        }
    }

    func refreshStatus(force: Bool) async {
        guard settings.calendarIntegrationEnabled else {
            availableCalendars = []
            agendaSnapshot = nil
            connectedAccount = nil
            lastNonBlockingError = nil
            lastBlockingError = nil
            integrationStatus = .disabled
            return
        }

        guard !settings.googleCalendarClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            availableCalendars = []
            agendaSnapshot = nil
            connectedAccount = nil
            lastBlockingError = nil
            integrationStatus = .clientConfigurationRequired
            return
        }

        do {
            let tokens = try await validTokenSet(forceRefresh: force)
            log("Calendar status refresh has valid token expiring at \(tokens.expiresAt)")
            connectedAccount = account(from: tokens)
            lastBlockingError = nil
            integrationStatus = .ready
            await refreshCalendars(force: force)
            if integrationStatus == .ready, !settings.selectedGoogleCalendarID.isEmpty {
                await refreshAgenda(force: force)
            }
        } catch let error as GoogleCalendarError {
            availableCalendars = []
            agendaSnapshot = nil
            connectedAccount = nil
            integrationStatus = error.integrationStatus
        } catch {
            availableCalendars = []
            agendaSnapshot = nil
            connectedAccount = nil
            integrationStatus = .error("Google Calendar setup failed: \(error.localizedDescription)")
        }
    }

    func beginSignIn() {
        guard settings.calendarIntegrationEnabled else {
            integrationStatus = .disabled
            return
        }

        let clientID = settings.googleCalendarClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            integrationStatus = .clientConfigurationRequired
            return
        }

        lastBlockingError = nil
        integrationStatus = .loading("Waiting for Google sign-in…")
        log("Starting Google OAuth flow")

        Task { @MainActor in
            do {
                let request = try await makeAuthorizationRequest(clientID: clientID)
                pendingAuthorization = request
                log("Opening Google OAuth URL with redirect \(request.redirectURI)")
                openBrowser(request.url)
            } catch {
                log("Failed to start Google OAuth flow: \(error.localizedDescription)")
                integrationStatus = .error("Unable to start Google sign-in: \(error.localizedDescription)")
            }
        }
    }

    func signOut() {
        KeychainHelper.delete(key: AppSettings.Keys.googleCalendarRefreshToken)
        KeychainHelper.delete(key: AppSettings.Keys.googleCalendarAccessToken)
        KeychainHelper.delete(key: AppSettings.Keys.googleCalendarIDToken)
        settings.googleCalendarTokenExpiry = 0
        settings.googleCalendarAccountEmail = ""
        settings.googleCalendarAccountName = ""
        settings.selectedGoogleCalendarID = ""
        settings.selectedGoogleCalendarName = ""
        cachedTokens = nil
        connectedAccount = nil
        availableCalendars = []
        agendaSnapshot = nil
        lastBlockingError = nil
        integrationStatus = settings.calendarIntegrationEnabled ? .authRequired : .disabled
    }

    func refreshCalendars(force: Bool = true) async {
        guard settings.calendarIntegrationEnabled else {
            integrationStatus = .disabled
            return
        }

        if !force, !availableCalendars.isEmpty {
            integrationStatus = .ready
            return
        }

        integrationStatus = .loading("Loading Google calendars…")

        do {
            let token = try await accessToken()
            let request = Self.authorizedRequest(
                url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!,
                accessToken: token,
                queryItems: [
                    URLQueryItem(name: "minAccessRole", value: "reader"),
                    URLQueryItem(name: "showDeleted", value: "false"),
                    URLQueryItem(name: "showHidden", value: "false")
                ]
            )

            let result = try await sendRequest(request)
            guard (200..<300).contains(result.response.statusCode) else {
                try handleGoogleErrorResponse(result, fallback: "Unable to load Google calendars.")
                return
            }

            let response = try Self.makeJSONDecoder().decode(GoogleCalendarListResponse.self, from: result.data)
            let calendars = response.items
                .map {
                    CalendarListItem(
                        id: $0.id,
                        name: $0.summaryOverride ?? $0.summary,
                        isPrimary: $0.primary ?? false
                    )
                }
                .sorted {
                    if $0.isPrimary != $1.isPrimary {
                        return $0.isPrimary && !$1.isPrimary
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            availableCalendars = calendars

            if let selected = calendars.first(where: { $0.id == settings.selectedGoogleCalendarID }) {
                settings.selectedGoogleCalendarName = selected.name
            } else if let preferred = calendars.first(where: \.isPrimary) ?? calendars.first {
                settings.selectedGoogleCalendarID = preferred.id
                settings.selectedGoogleCalendarName = preferred.name
            } else {
                settings.selectedGoogleCalendarID = ""
                settings.selectedGoogleCalendarName = ""
            }

            integrationStatus = .ready
        } catch let error as GoogleCalendarError {
            integrationStatus = error.integrationStatus
        } catch {
            integrationStatus = .error("Unable to load Google calendars: \(error.localizedDescription)")
        }
    }

    func refreshAgenda(force: Bool = false) async {
        guard settings.calendarIntegrationEnabled else {
            integrationStatus = .disabled
            agendaSnapshot = nil
            return
        }

        if !force, let agendaSnapshot, nowProvider().timeIntervalSince(agendaSnapshot.generatedAt) < agendaTTL {
            return
        }

        if settings.selectedGoogleCalendarID.isEmpty {
            await refreshCalendars(force: true)
            guard !settings.selectedGoogleCalendarID.isEmpty else { return }
        }

        integrationStatus = .loading("Loading calendar agenda…")

        do {
            let token = try await accessToken()
            let now = nowProvider()
            let request = Self.authorizedRequest(
                url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(settings.selectedGoogleCalendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.selectedGoogleCalendarID)/events")!,
                accessToken: token,
                queryItems: [
                    URLQueryItem(name: "timeMin", value: now.ISO8601Format()),
                    URLQueryItem(name: "timeMax", value: Self.endOfTomorrow(relativeTo: now).ISO8601Format()),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "50")
                ]
            )

            let result = try await sendRequest(request)
            guard (200..<300).contains(result.response.statusCode) else {
                try handleGoogleErrorResponse(result, fallback: "Unable to load calendar events.", preserveAgenda: true)
                return
            }

            let response = try Self.makeJSONDecoder().decode(GoogleCalendarEventsResponse.self, from: result.data)
            let events = response.items.compactMap {
                Self.makeAgendaEvent(from: $0, calendarID: settings.selectedGoogleCalendarID, calendarName: settings.selectedGoogleCalendarName)
            }

            agendaSnapshot = CalendarAgendaSnapshot(
                generatedAt: now,
                buckets: CalendarAgendaSnapshot.makeBuckets(from: events, now: now),
                allEvents: events
            )
            lastNonBlockingError = nil
            integrationStatus = .ready
        } catch let error as GoogleCalendarError {
            integrationStatus = error.integrationStatus
        } catch {
            if agendaSnapshot != nil {
                lastNonBlockingError = "Calendar refresh failed: \(error.localizedDescription)"
                integrationStatus = .ready
            } else {
                integrationStatus = .error("Unable to load calendar events: \(error.localizedDescription)")
            }
        }
    }

    func selectCalendar(id: String) {
        settings.selectedGoogleCalendarID = id
        settings.selectedGoogleCalendarName = availableCalendars.first(where: { $0.id == id })?.name ?? ""
        Task { @MainActor in
            await refreshAgenda(force: true)
        }
    }

    func callContextForRecording(at date: Date = Date()) async -> CallContext? {
        guard settings.calendarIntegrationEnabled else { return nil }

        if let agendaSnapshot {
            if date.timeIntervalSince(agendaSnapshot.generatedAt) >= agendaTTL {
                await refreshAgenda(force: true)
            }
        } else {
            await refreshAgenda(force: true)
        }

        guard let matched = Self.matchRecordingEvent(from: agendaSnapshot?.allEvents ?? [], at: date) else { return nil }
        return matched.makeCallContext()
    }

    nonisolated package static func matchRecordingEvent(from events: [CalendarAgendaEvent], at date: Date) -> CalendarAgendaEvent? {
        if let active = events
            .filter({ $0.startAt <= date && $0.endAt > date })
            .sorted(by: { $0.startAt < $1.startAt })
            .first {
            return active
        }

        let leadTime = date.addingTimeInterval(15 * 60)
        return events
            .filter { $0.startAt > date && $0.startAt <= leadTime }
            .sorted(by: { $0.startAt < $1.startAt })
            .first
    }

    nonisolated package static func authorizationURL(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        state: String
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.oauthScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    nonisolated package static func makeAgendaEvent(from event: GoogleCalendarEvent, calendarID: String, calendarName: String) -> CalendarAgendaEvent? {
        guard event.status != "cancelled" else { return nil }
        guard let startInfo = parseEventDate(event.start) else { return nil }
        guard let endInfo = parseEventDate(event.end) else { return nil }

        let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees = (event.attendees ?? []).map {
            CalendarAttendee(
                displayName: $0.displayName,
                email: $0.email,
                responseStatus: $0.responseStatus,
                isSelf: $0.selfValue ?? false
            )
        }

        return CalendarAgendaEvent(
            id: event.id,
            title: (title?.isEmpty == false ? title : "Untitled Event") ?? "Untitled Event",
            startAt: startInfo.date,
            endAt: endInfo.date,
            isAllDay: startInfo.isAllDay,
            attendees: attendees,
            eventURL: event.htmlLink.flatMap(URL.init(string:)),
            meetingURL: meetingURL(from: event),
            calendarID: calendarID,
            calendarName: calendarName
        )
    }

    private func makeAuthorizationRequest(clientID: String) async throws -> GoogleCalendarAuthorizationRequest {
        let verifier = Self.randomURLSafeString(length: 64)
        let state = Self.randomURLSafeString(length: 32)
        let challenge = Self.codeChallenge(for: verifier)
        let callbackServer = try await GoogleOAuthCallbackServer.start()
        self.callbackServer = callbackServer

        Task.detached { [weak self] in
            do {
                let callback = try await callbackServer.waitForCallback()
                await self?.log("Received OAuth callback")
                await self?.handleAuthorizationCallback(callback)
            } catch {
                await self?.log("OAuth callback wait failed: \(error.localizedDescription)")
                await self?.handleAuthorizationFailure(error)
            }
        }

        guard let redirectURI = callbackServer.redirectURI?.absoluteString else {
            throw GoogleCalendarError.other("OAuth callback listener did not produce a redirect URI.")
        }
        return GoogleCalendarAuthorizationRequest(
            url: Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge, state: state),
            verifier: verifier,
            state: state,
            redirectURI: redirectURI
        )
    }

    private func handleAuthorizationFailure(_ error: Error) {
        pendingAuthorization = nil
        callbackServer = nil
        let message = "Google sign-in failed: \(error.localizedDescription)"
        lastBlockingError = message
        integrationStatus = .error(message)
    }

    private func handleAuthorizationCallback(_ callback: GoogleOAuthCallback) async {
        defer {
            pendingAuthorization = nil
            callbackServer = nil
        }

        guard let pendingAuthorization else {
            integrationStatus = .error("Google sign-in returned unexpectedly.")
            return
        }

        if let error = callback.error {
            let message = "Google sign-in failed: \(error)"
            log(message)
            lastBlockingError = message
            integrationStatus = .error(message)
            return
        }

        guard callback.state == pendingAuthorization.state else {
            let message = "Google sign-in state mismatch."
            log(message)
            lastBlockingError = message
            integrationStatus = .error(message)
            return
        }

        guard let code = callback.code else {
            let message = "Google sign-in returned no authorization code."
            log(message)
            lastBlockingError = message
            integrationStatus = .error(message)
            return
        }

        do {
            log("Exchanging OAuth authorization code for tokens")
            let tokens = try await exchangeAuthorizationCode(
                code: code,
                clientID: settings.googleCalendarClientID,
                redirectURI: pendingAuthorization.redirectURI,
                verifier: pendingAuthorization.verifier
            )
            storeTokens(tokens)
            log("Stored Google tokens in Keychain")
            connectedAccount = account(from: tokens)
            lastBlockingError = nil
            await refreshStatus(force: true)
        } catch let error as GoogleCalendarError {
            log("Google OAuth exchange failed: \(error.localizedDescription)")
            lastBlockingError = error.localizedDescription
            integrationStatus = error.integrationStatus
        } catch {
            let message = "Unable to finish Google sign-in: \(error.localizedDescription)"
            log(message)
            lastBlockingError = message
            integrationStatus = .error(message)
        }
    }

    private func accessToken() async throws -> String {
        try await validTokenSet(forceRefresh: false).accessToken
    }

    private func validTokenSet(forceRefresh: Bool) async throws -> GoogleCalendarTokenSet {
        let now = nowProvider()

        if let cachedTokens, cachedTokens.expiresAt > now.addingTimeInterval(60) {
            return cachedTokens
        }

        if let restored = restoreTokens(), restored.expiresAt > now.addingTimeInterval(60) {
            cachedTokens = restored
            return restored
        }

        guard let refreshToken = KeychainHelper.load(key: AppSettings.Keys.googleCalendarRefreshToken), !refreshToken.isEmpty else {
            if let lastBlockingError, !lastBlockingError.isEmpty {
                log("No refresh token in Keychain; surfacing last blocking error: \(lastBlockingError)")
                throw GoogleCalendarError.other(lastBlockingError)
            }
            log("No refresh token in Keychain")
            throw GoogleCalendarError.authRequired
        }

        log("Refreshing Google access token")
        let refreshed = try await refreshAccessToken(
            refreshToken: refreshToken,
            clientID: settings.googleCalendarClientID
        )
        storeTokens(refreshed)
        return refreshed
    }

    private func exchangeAuthorizationCode(
        code: String,
        clientID: String,
        redirectURI: String,
        verifier: String
    ) async throws -> GoogleCalendarTokenSet {
        let clientSecret = resolvedGoogleClientSecret()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parameters = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        if let clientSecret, !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        request.httpBody = Self.formBody(parameters)

        let result = try await sendRequest(request)
        guard (200..<300).contains(result.response.statusCode) else {
            let message = Self.decodeGoogleErrorMessage(from: result.data, fallback: "Google token exchange failed.")
            log("Google token exchange HTTP \(result.response.statusCode): \(message)")
            throw GoogleCalendarError.other(Self.userFacingAuthErrorMessage(from: message))
        }

        let response = try Self.makeJSONDecoder().decode(GoogleOAuthTokenResponse.self, from: result.data)
        guard let refreshToken = response.refreshToken else {
            log("Google token exchange returned no refresh token")
            throw GoogleCalendarError.other("Google did not return a refresh token.")
        }

        return GoogleCalendarTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            idToken: response.idToken,
            expiresAt: nowProvider().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private func refreshAccessToken(refreshToken: String, clientID: String) async throws -> GoogleCalendarTokenSet {
        let clientSecret = resolvedGoogleClientSecret()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parameters = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let clientSecret, !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        request.httpBody = Self.formBody(parameters)

        let result = try await sendRequest(request)
        guard (200..<300).contains(result.response.statusCode) else {
            let message = Self.decodeGoogleErrorMessage(from: result.data, fallback: "Google token refresh failed.")
            log("Google token refresh HTTP \(result.response.statusCode): \(message)")
            throw GoogleCalendarError.other(Self.userFacingAuthErrorMessage(from: message))
        }

        let response = try Self.makeJSONDecoder().decode(GoogleOAuthTokenResponse.self, from: result.data)
        let existingIDToken = KeychainHelper.load(key: AppSettings.Keys.googleCalendarIDToken)
        return GoogleCalendarTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            idToken: response.idToken ?? existingIDToken,
            expiresAt: nowProvider().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private func storeTokens(_ tokens: GoogleCalendarTokenSet) {
        cachedTokens = tokens
        KeychainHelper.save(key: AppSettings.Keys.googleCalendarRefreshToken, value: tokens.refreshToken)
        KeychainHelper.save(key: AppSettings.Keys.googleCalendarAccessToken, value: tokens.accessToken)
        if let idToken = tokens.idToken {
            KeychainHelper.save(key: AppSettings.Keys.googleCalendarIDToken, value: idToken)
        }
        settings.googleCalendarTokenExpiry = Int(tokens.expiresAt.timeIntervalSince1970)

        let account = account(from: tokens)
        settings.googleCalendarAccountEmail = account?.email ?? ""
        settings.googleCalendarAccountName = account?.name ?? ""
    }

    private func restoreTokens() -> GoogleCalendarTokenSet? {
        guard
            let refreshToken = KeychainHelper.load(key: AppSettings.Keys.googleCalendarRefreshToken),
            let accessToken = KeychainHelper.load(key: AppSettings.Keys.googleCalendarAccessToken),
            !refreshToken.isEmpty,
            !accessToken.isEmpty
        else {
            return nil
        }

        let expiry = Date(timeIntervalSince1970: TimeInterval(settings.googleCalendarTokenExpiry))
        let idToken = KeychainHelper.load(key: AppSettings.Keys.googleCalendarIDToken)
        return GoogleCalendarTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiry
        )
    }

    private func resolvedGoogleClientSecret() -> String? {
        let bundledSecret = settings.googleCalendarClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundledSecret.isEmpty {
            return bundledSecret
        }

        let legacyKeychainSecret = KeychainHelper.load(key: AppSettings.Keys.googleCalendarClientSecret)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacyKeychainSecret, !legacyKeychainSecret.isEmpty {
            return legacyKeychainSecret
        }

        return nil
    }

    private func account(from tokens: GoogleCalendarTokenSet) -> GoogleCalendarAccount? {
        if !settings.googleCalendarAccountEmail.isEmpty {
            return GoogleCalendarAccount(
                email: settings.googleCalendarAccountEmail,
                name: settings.googleCalendarAccountName.isEmpty ? nil : settings.googleCalendarAccountName
            )
        }

        guard let idToken = tokens.idToken else { return nil }
        guard let payload = Self.decodeJWTPayload(idToken),
              let email = payload["email"] as? String
        else {
            return nil
        }

        let name = payload["name"] as? String
        return GoogleCalendarAccount(email: email, name: name)
    }

    private func handleGoogleErrorResponse(
        _ result: GoogleCalendarHTTPResult,
        fallback: String,
        preserveAgenda: Bool = false
    ) throws {
        let message = Self.decodeGoogleErrorMessage(from: result.data, fallback: fallback)
        let status = result.response.statusCode
        log("Google Calendar API HTTP \(status): \(message)")

        if status == 401 {
            if preserveAgenda, agendaSnapshot != nil {
                lastNonBlockingError = message
                integrationStatus = .ready
                return
            }
            throw GoogleCalendarError.authRequired
        }

        if status == 403 {
            if preserveAgenda, agendaSnapshot != nil {
                lastNonBlockingError = message
                integrationStatus = .ready
                return
            }
            throw GoogleCalendarError.other(message)
        }

        if preserveAgenda, agendaSnapshot != nil {
            lastNonBlockingError = message
            integrationStatus = .ready
            return
        }

        throw GoogleCalendarError.other(message)
    }

    private static func authorizedRequest(url: URL, accessToken: String, queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        let encoded = values
            .map { key, value in
                "\(key.urlQueryEscaped)=\(value.urlQueryEscaped)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let components = token.split(separator: ".")
        guard components.count >= 2 else { return nil }
        let payload = String(components[1])
        guard let data = Data(base64URLEncoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated package static func parseEventDate(_ value: GoogleCalendarEventDate?) -> (date: Date, isAllDay: Bool)? {
        guard let value else { return nil }

        if let dateTime = value.dateTime {
            if let parsed = Self.makeISO8601Formatter(withFractionalSeconds: true).date(from: dateTime) {
                return (parsed, false)
            }
            if let parsed = Self.makeISO8601Formatter(withFractionalSeconds: false).date(from: dateTime) {
                return (parsed, false)
            }
        }

        if let date = value.date, let parsed = Self.makeDateOnlyFormatter().date(from: date) {
            return (parsed, true)
        }

        return nil
    }

    nonisolated package static func meetingURL(from event: GoogleCalendarEvent) -> URL? {
        if let hangoutLink = event.hangoutLink, let url = URL(string: hangoutLink) {
            return url
        }

        let entryPoints = event.conferenceData?.entryPoints ?? []
        return entryPoints.compactMap(\.uri).compactMap(URL.init(string:)).first
    }

    private static func endOfTomorrow(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: date)
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? date
        return startOfDayAfterTomorrow.addingTimeInterval(-1)
    }

    private static func liveHTTPSender(_ request: URLRequest) async throws -> GoogleCalendarHTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.other("Invalid HTTP response.")
        }
        return GoogleCalendarHTTPResult(data: data, response: httpResponse)
    }

    nonisolated private static let oauthScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]

    nonisolated private static func makeDateOnlyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    nonisolated private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func makeISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    nonisolated private static func decodeGoogleErrorMessage(from data: Data, fallback: String) -> String {
        let envelope = try? makeJSONDecoder().decode(GoogleCalendarAPIErrorEnvelope.self, from: data)
        return envelope?.error.message ?? String(data: data, encoding: .utf8) ?? fallback
    }

    nonisolated private static func userFacingAuthErrorMessage(from rawMessage: String) -> String {
        let normalized = rawMessage.lowercased()
        if normalized.contains("client_secret is missing") {
            return "Google rejected this OAuth client because it requires a client secret. Spool needs a Google OAuth Desktop app client ID instead."
        }

        if normalized.contains("invalid_client") {
            return "Google rejected the configured OAuth client. Verify that Spool is using a valid Google OAuth Desktop app client ID."
        }

        return rawMessage
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL, options: .atomic)
        }
    }
}

enum GoogleCalendarError: LocalizedError {
    case authRequired
    case clientConfigurationRequired
    case other(String)

    var integrationStatus: CalendarIntegrationStatus {
        switch self {
        case .authRequired:
            return .authRequired
        case .clientConfigurationRequired:
            return .clientConfigurationRequired
        case .other(let message):
            return .error(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .authRequired:
            return "Google Calendar access is not connected yet."
        case .clientConfigurationRequired:
            return "Add a Google OAuth client ID to connect Google Calendar."
        case .other(let message):
            return message
        }
    }
}

private struct GoogleOAuthTokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

private struct GoogleCalendarAPIErrorEnvelope: Codable {
    struct GoogleCalendarAPIError: Codable {
        let code: Int?
        let message: String
    }

    let error: GoogleCalendarAPIError
}

package struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarListEntry]
}

package struct GoogleCalendarListEntry: Decodable {
    let id: String
    let summary: String
    let summaryOverride: String?
    let primary: Bool?
}

package struct GoogleCalendarEventsResponse: Decodable {
    let items: [GoogleCalendarEvent]
}

package struct GoogleCalendarEvent: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: GoogleCalendarEventDate?
    let end: GoogleCalendarEventDate?
    let attendees: [GoogleCalendarEventAttendee]?
    let conferenceData: GoogleCalendarConferenceData?
}

package struct GoogleCalendarEventDate: Decodable {
    let dateTime: String?
    let date: String?
}

package struct GoogleCalendarEventAttendee: Decodable {
    let displayName: String?
    let email: String?
    let responseStatus: String?
    let selfValue: Bool?

    enum CodingKeys: String, CodingKey {
        case displayName
        case email
        case responseStatus
        case selfValue = "self"
    }
}

package struct GoogleCalendarConferenceData: Decodable {
    let entryPoints: [GoogleCalendarConferenceEntryPoint]?
}

package struct GoogleCalendarConferenceEntryPoint: Decodable {
    let uri: String?
}

private struct GoogleOAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

private final class GoogleOAuthCallbackServer: @unchecked Sendable {
    private(set) var redirectURI: URL?

    private let listener: NWListener
    private var callbackContinuation: CheckedContinuation<GoogleOAuthCallback, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    static func start() async throws -> GoogleOAuthCallbackServer {
        let server = try GoogleOAuthCallbackServer()
        try await server.waitUntilReady()
        return server
    }

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }
        listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let callbackServer = self else {
                    connection.cancel()
                    return
                }
                let callback = Self.parseCallback(from: data)
                let body = """
                <html><body style="font-family: -apple-system; padding: 24px;">
                <h2>Spool connected to Google Calendar.</h2>
                <p>You can close this window and return to the app.</p>
                </body></html>
                """
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    callbackServer.listener.cancel()
                    callbackServer.finish(callback)
                })
            }
        }
    }

    private func waitUntilReady() async throws {
        if redirectURI != nil {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
        }
    }

    func waitForCallback() async throws -> GoogleOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            callbackContinuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ callback: GoogleOAuthCallback) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.resume(returning: callback)
    }

    private func finishReady(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port {
                redirectURI = URL(string: "http://127.0.0.1:\(port)/oauth2callback")
                finishReady(with: .success(()))
            } else {
                finishReady(with: .failure(GoogleCalendarError.other("OAuth callback listener started without a port.")))
            }
        case .failed(let error):
            finishReady(with: .failure(error))
        case .cancelled:
            if redirectURI == nil {
                finishReady(with: .failure(GoogleCalendarError.other("OAuth callback listener was cancelled before startup.")))
            }
        default:
            break
        }
    }

    private static func parseCallback(from data: Data?) -> GoogleOAuthCallback {
        guard let data, let request = String(data: data, encoding: .utf8) else {
            return GoogleOAuthCallback(code: nil, state: nil, error: "Missing Google callback payload.")
        }

        guard let firstLine = request.split(separator: "\r\n").first else {
            return GoogleOAuthCallback(code: nil, state: nil, error: "Malformed Google callback request.")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://localhost\(parts[1])") else {
            return GoogleOAuthCallback(code: nil, state: nil, error: "Malformed Google callback URL.")
        }

        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        let error = components.queryItems?.first(where: { $0.name == "error" })?.value
        return GoogleOAuthCallback(code: code, state: state, error: error)
    }
}

private extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? self
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        let base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64 + padding)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
