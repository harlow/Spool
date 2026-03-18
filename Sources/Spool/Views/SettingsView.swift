import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var recordingController: RecordingController

    init(settings: AppSettings, recordingController: RecordingController) {
        self.settings = settings
        self.recordingController = recordingController
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

            Section("Status") {
                Text(recordingController.statusLine ?? "Idle")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
    }
}
