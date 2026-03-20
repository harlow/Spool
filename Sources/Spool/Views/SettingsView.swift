import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var recordingController: RecordingController
    @Bindable var calendarService: GoogleCalendarService
    @Bindable var meetingReminderService: MeetingReminderService

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
        settings.loadSummaryAPIKeyIfNeeded()
    }

    var body: some View {
        Form {
            Section("Output") {
                HStack {
                    TextField("Output Folder", text: $settings.outputRootPath)
                    Button("Choose") {
                        settings.chooseOutputRoot()
                    }
                }

                Text("Sessions are stored under year/month folders. Summary files use the date plus an inferred title slug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Summary") {
                Picker("Provider", selection: $settings.summaryProvider) {
                    ForEach(SummaryProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                TextField("Model", text: $settings.summaryModel)
                TextField(settings.summaryProvider.endpointLabel, text: $settings.summaryEndpoint)

                if settings.summaryProvider.requiresAPIKey {
                    SecureField(settings.summaryProvider.apiKeyLabel, text: $settings.summaryApiKey)
                }

                Text(settings.summaryConfigurationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                Toggle("Show Google Calendar agenda", isOn: $settings.calendarIntegrationEnabled)
                    .onChange(of: settings.calendarIntegrationEnabled) { _, _ in
                        Task { await calendarService.refreshStatus(force: true) }
                    }

                Text(calendarService.integrationStatus.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let account = calendarService.connectedAccount {
                    Text("Connected as \(account.email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastError = calendarService.lastNonBlockingError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastBlockingError = calendarService.lastBlockingError, !lastBlockingError.isEmpty {
                    Text(lastBlockingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Connect Google") {
                        calendarService.beginSignIn()
                    }
                    Button("Refresh Calendars") {
                        Task { await calendarService.refreshCalendars(force: true) }
                    }
                    Button("Sign Out") {
                        calendarService.signOut()
                    }
                }

                Picker("Calendar", selection: $settings.selectedGoogleCalendarID) {
                    Text("Select a calendar").tag("")
                    ForEach(calendarService.availableCalendars) { item in
                        Text(item.name + (item.isPrimary ? " (Primary)" : "")).tag(item.id)
                    }
                }
                .disabled(calendarService.availableCalendars.isEmpty || !settings.calendarIntegrationEnabled)
                .onChange(of: settings.selectedGoogleCalendarID) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    calendarService.selectCalendar(id: newValue)
                }
            }

            Section("Shortcuts") {
                Text("Global shortcuts are temporarily disabled.")
                Text("The app does not currently register a working hotkey, so no shortcut is shown in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Open summary when complete", isOn: $settings.openSummaryOnCompletion)
                Toggle("Open session folder when complete", isOn: $settings.openSessionFolderOnCompletion)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Meeting Reminders") {
                LabeledContent("Notifications", value: meetingReminderService.notificationAccessLabel)
                Text(meetingReminderService.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = meetingReminderService.lastAuthorizationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Refresh reminders") {
                        Task { await meetingReminderService.refreshNow() }
                    }

                    Button("Send test notification") {
                        Task { await meetingReminderService.sendTestNotification() }
                    }

                    Button("Open Notification Settings") {
                        meetingReminderService.openSystemNotificationSettings()
                    }
                }

                Text("Spool scans your Google Calendar agenda and shows a join-and-record reminder about two minutes before meetings with join links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(recordingController.statusLine ?? "Idle")
            }
        }
        .task {
            await calendarService.refreshStatus(force: false)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 560, minHeight: 560)
    }
}
