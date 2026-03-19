import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class RecordingController {
    private let settings: AppSettings
    private let sessionStorage: SessionStorage
    private let transcriptStore = TranscriptStore()
    private let transcriptionEngine = TranscriptionEngine()
    private let summaryService: OpenAISummaryService
    private let calendarService: GoogleCalendarService
    var onSetupRequired: (() -> Void)?

    var state: RecordingState = .idle
    var currentSession: SessionDescriptor?
    var latestCompletedSession: SessionDescriptor?
    var errorMessage: String?
    var blockingIssueMessage: String?

    init(settings: AppSettings, calendarService: GoogleCalendarService) {
        self.settings = settings
        self.sessionStorage = SessionStorage(settings: settings)
        self.summaryService = OpenAISummaryService(settings: settings)
        self.calendarService = calendarService
        self.state = settings.needsOnboarding ? .idle : .ready

        transcriptStore.onAppend = { [weak self] utterance in
            guard let self, let session = self.currentSession else { return }
            do {
                try self.sessionStorage.appendUtterance(utterance, to: session)
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                    self.sessionStorage.appendLog("Failed to append utterance: \(error.localizedDescription)", to: session)
                }
            }
        }

        transcriptionEngine.onPartial = { [weak self] speaker, text in
            Task { @MainActor in
                guard let self else { return }
                switch speaker {
                case .you:
                    self.transcriptStore.volatileYouText = text
                case .them:
                    self.transcriptStore.volatileThemText = text
                }
            }
        }

        transcriptionEngine.onUtterance = { [weak self] utterance in
            Task { @MainActor in
                self?.transcriptStore.append(utterance)
            }
        }

        refreshStartupState()
    }

    var primaryActionTitle: String {
        let baseTitle: String
        switch state {
        case .recording:
            baseTitle = "Stop Recording"
        case .stopping, .finalizingTranscript, .summarizing:
            baseTitle = "Processing..."
        default:
            if settings.outputRootPath.isEmpty {
                baseTitle = "Open Settings"
            } else {
                baseTitle = "Quick Recording"
            }
        }

        return baseTitle
    }

    var statusLine: String? {
        switch state {
        case .idle:
            return blockingIssueMessage ?? (settings.needsOnboarding ? "Setup required" : nil)
        case .ready:
            return blockingIssueMessage
        case .recording:
            return "Recording"
        case .stopping:
            return "Stopping..."
        case .finalizingTranscript:
            return "Finalizing transcript..."
        case .summarizing:
            return "Summarizing..."
        case .completed:
            return "Latest summary ready"
        case .failed:
            return errorMessage ?? "Failed"
        case .checkingPermissions:
            return "Checking permissions..."
        }
    }

    func performPrimaryAction() async {
        switch state {
        case .recording:
            await stopRecording()
        case .stopping, .finalizingTranscript, .summarizing:
            break
        default:
            if settings.outputRootPath.isEmpty {
                onSetupRequired?()
                return
            }
            _ = await startPlainRecording()
        }
    }

    func refreshStartupState() {
        if settings.needsOnboarding {
            blockingIssueMessage = settings.outputRootPath.isEmpty
                ? "Choose an output folder in Settings."
                : "Add your OpenAI API key in Settings."
            state = .idle
            return
        }

        blockingIssueMessage = transcriptionEngine.currentPermissionMessage()
        if state != .recording && state != .stopping && state != .finalizingTranscript && state != .summarizing {
            state = blockingIssueMessage == nil ? .ready : .idle
        }
    }

    func warmUpPermissionsOnLaunch() async {
        await transcriptionEngine.warmUpSystemAudioPermission()
        refreshStartupState()
    }

    var canStartNewRecording: Bool {
        switch state {
        case .idle, .ready, .completed, .failed:
            return true
        case .recording, .stopping, .finalizingTranscript, .summarizing, .checkingPermissions:
            return false
        }
    }

    func startPlainRecording() async -> Bool {
        await startRecording(callContext: nil)
    }

    func startRecording(for event: CalendarAgendaEvent) async -> Bool {
        await startRecording(callContext: event.makeCallContext())
    }

    @discardableResult
    func startRecording(callContext: CallContext?) async -> Bool {
        errorMessage = nil
        settings.loadSummaryAPIKeyIfNeeded()

        guard !settings.needsOnboarding else {
            state = .failed
            errorMessage = "Finish setup before starting a recording."
            onSetupRequired?()
            return false
        }

        guard !settings.isSummaryAPIKeyMissing else {
            state = .failed
            errorMessage = "Add your OpenAI API key in Settings."
            onSetupRequired?()
            return false
        }

        guard canStartNewRecording else {
            return false
        }

        state = .checkingPermissions

        if let permissionMessage = await transcriptionEngine.requestPermissionsIfNeeded() {
            blockingIssueMessage = permissionMessage
            state = .idle
            errorMessage = permissionMessage
            sessionStorage.appendLog("Permission/startup block: \(permissionMessage)", to: currentSession)
            return false
        }

        do {
            blockingIssueMessage = nil
            transcriptStore.clear()
            let descriptor = try sessionStorage.createSession(callContext: callContext)
            currentSession = descriptor
            await transcriptionEngine.start(locale: Locale(identifier: settings.transcriptionLocale))
            if let engineError = transcriptionEngine.lastError, !transcriptionEngine.isRunning {
                currentSession = nil
                throw NSError(domain: "Spool", code: 1, userInfo: [NSLocalizedDescriptionKey: engineError])
            }
            state = .recording
            return true
        } catch {
            currentSession = nil
            blockingIssueMessage = shortErrorMessage(error.localizedDescription)
            state = .idle
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stopRecording() async {
        guard var session = currentSession else { return }

        do {
            state = .stopping
            await transcriptionEngine.stop()
            state = .finalizingTranscript
            let transcript = try sessionStorage.finalizeTranscript(for: session, utterances: transcriptStore.utterances)
            state = .summarizing
            let summary = try await summaryService.summarize(transcript: transcript, descriptor: session)
            session = try sessionStorage.renameSession(session, summaryTitle: summary.title)
            _ = try sessionStorage.finalizeTranscript(for: session, utterances: transcriptStore.utterances)
            try sessionStorage.writeSummary(summary.markdown, for: session)
            try sessionStorage.completeSession(session)
            latestCompletedSession = session
            currentSession = nil
            refreshStartupState()
            state = .completed

            if settings.openSummaryOnCompletion {
                openLatestSummary()
            } else if settings.openSessionFolderOnCompletion {
                openLatestSessionFolder()
            }
        } catch {
            if let session = currentSession {
                try? sessionStorage.markSummaryFailed(session)
                sessionStorage.appendLog("Summary failed: \(error.localizedDescription)", to: session)
            }
            currentSession = nil
            errorMessage = error.localizedDescription
            blockingIssueMessage = "Summary failed: \(shortErrorMessage(error.localizedDescription))"
            state = .idle
        }
    }

    func openLatestSummary() {
        guard let url = latestCompletedSession?.paths.summaryURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openLatestSessionFolder() {
        let url = currentSession?.paths.folderURL ?? latestCompletedSession?.paths.folderURL
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func shortErrorMessage(_ message: String) -> String {
        let collapsed = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 110 {
            return collapsed
        }
        let index = collapsed.index(collapsed.startIndex, offsetBy: 107)
        return "\(collapsed[..<index])..."
    }
}
