import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @Bindable var meetingReminderService: MeetingReminderService

    let onDone: () -> Void

    @State private var stepIndex = 0

    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = []

        if !settings.didReviewRecordingAccess, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            result.append(.microphone)
        }

        if !settings.didReviewKeychainAccess {
            result.append(.keychain)
        }

        if !settings.didReviewNotificationAccess, meetingReminderService.notificationAuthorizationStatus == .notDetermined {
            result.append(.notifications)
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Spool Onboarding")
                .font(.title2.weight(.semibold))

            if let step = currentStep {
                Text(step.title)
                    .font(.title.weight(.semibold))

                Text(step.detail)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        stepBody(step)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }

                Spacer()

                HStack {
                    HStack(spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                            Circle()
                                .fill(index == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 8, height: 8)
                        }
                    }

                    Spacer()

                    if stepIndex > 0 {
                        Button("Back") {
                            stepIndex -= 1
                        }
                    }

                    Button(stepIndex == steps.count - 1 ? "Done" : "Next") {
                        advance()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("No onboarding steps are pending.")
                    .foregroundStyle(.secondary)

                Spacer()

                HStack {
                    Spacer()
                    Button("Done") {
                        onDone()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
        .task {
            await meetingReminderService.refreshAuthorizationStatus()
            clampStepIndex()
        }
        .onChange(of: stepSignature) { _, _ in
            clampStepIndex()
        }
    }

    private var currentStep: OnboardingStep? {
        guard !steps.isEmpty else { return nil }
        return steps[min(stepIndex, steps.count - 1)]
    }

    private var stepSignature: String {
        steps.map(\.rawValue).joined(separator: "|")
    }

    private func clampStepIndex() {
        if steps.isEmpty {
            stepIndex = 0
        } else {
            stepIndex = min(stepIndex, steps.count - 1)
        }
    }

    private func advance() {
        markCurrentStepReviewed()
        if steps.isEmpty || stepIndex == steps.count - 1 {
            onDone()
        } else {
            stepIndex += 1
        }
    }

    @ViewBuilder
    private func stepBody(_ step: OnboardingStep) -> some View {
        switch step {
        case .microphone:
            VStack(alignment: .leading, spacing: 12) {
                Text("No permissions are requested until you click the button below.")
                    .foregroundStyle(.secondary)

                Button("Enable Microphone Access") {
                    Task { await settingsMicrophoneAccess() }
                }
            }
        case .keychain:
            VStack(alignment: .leading, spacing: 12) {
                Text("Spool stores secrets in Keychain. macOS may ask for Keychain access later when you save or use your API key or Google credentials.")
                    .foregroundStyle(.secondary)
            }
        case .notifications:
            VStack(alignment: .leading, spacing: 12) {
                Text("This step asks macOS for permission to show the Join Meeting & record in Spool notification.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Enable Notifications") {
                        Task { await meetingReminderService.requestAuthorizationNow() }
                    }

                    if meetingReminderService.notificationAuthorizationStatus == .denied {
                        Button("Open Notification Settings") {
                            meetingReminderService.openSystemNotificationSettings()
                        }
                    }
                }

                if let error = meetingReminderService.lastAuthorizationError {
                    Text(error)
                        .foregroundStyle(.red)
                }

                if meetingReminderService.notificationsAuthorized {
                    Text("Notifications enabled.")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func settingsMicrophoneAccess() async {
        settings.didReviewRecordingAccess = true
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
            return
        }
    }

    private func markCurrentStepReviewed() {
        guard let currentStep else { return }

        switch currentStep {
        case .microphone:
            break
        case .keychain:
            settings.didReviewKeychainAccess = true
        case .notifications:
            break
        }
    }
}

private enum OnboardingStep: String {
    case microphone
    case keychain
    case notifications

    var title: String {
        switch self {
        case .microphone:
            "1. Enable Microphone Access"
        case .keychain:
            "2. Enable Keychain Access"
        case .notifications:
            "3. Enable Notifications"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            "Allow Spool to access the microphone before your first recording."
        case .keychain:
            "Prompt Keychain access for the stored Google credentials Spool relies on."
        case .notifications:
            "Allow banner notifications for meeting reminders."
        }
    }
}
