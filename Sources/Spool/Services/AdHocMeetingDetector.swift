import AppKit
import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.fieldgrid.spool", category: "AdHocMeetingDetector")

struct DetectedMeetingApp: Sendable, Equatable {
    let bundleID: String
    let name: String
}

@Observable
@MainActor
final class AdHocMeetingDetector {
    private let settings: AppSettings
    private let recordingController: RecordingController
    private let audioSource: any AudioSignalSource
    private var monitorTask: Task<Void, Never>?
    private var micActiveAt: Date?
    private var suppressedBundleIDs: Set<String> = []
    private var hasStarted = false

    private(set) var detectedApp: DetectedMeetingApp?

    var onMeetingDetected: ((DetectedMeetingApp?) -> Void)?
    var onMeetingEnded: (() -> Void)?

    private let debounceSeconds: TimeInterval = 5.0

    private static let selfBundleID = Bundle.main.bundleIdentifier ?? "com.fieldgrid.spool"

    private static let knownMeetingApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("app.tuple.app", "Tuple"),
        ("co.around.Around", "Around"),
        ("com.slack.Slack", "Slack"),
        ("com.hnc.Discord", "Discord"),
    ]

    init(
        settings: AppSettings,
        recordingController: RecordingController,
        audioSource: (any AudioSignalSource)? = nil
    ) {
        self.settings = settings
        self.recordingController = recordingController
        self.audioSource = audioSource ?? CoreAudioSignalSource()
    }

    func start() {
        guard !hasStarted else { return }
        guard settings.adHocMeetingDetectionEnabled else {
            logger.info("Ad-hoc meeting detection is disabled in settings")
            return
        }
        hasStarted = true
        logger.info("Ad-hoc meeting detector started")

        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await micIsActive in self.audioSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicSignal(micIsActive)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        hasStarted = false
        if detectedApp != nil {
            detectedApp = nil
            onMeetingEnded?()
        }
        micActiveAt = nil
        suppressedBundleIDs.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    func suppressCurrentApp() {
        if let app = detectedApp {
            suppressedBundleIDs.insert(app.bundleID)
        }
        detectedApp = nil
    }

    func resetDetection() {
        detectedApp = nil
    }

    private func handleMicSignal(_ micIsActive: Bool) async {
        if micIsActive {
            if micActiveAt == nil {
                micActiveAt = Date()
                logger.info("Mic became active, starting \(self.debounceSeconds)s debounce")
            }

            let activeSince = micActiveAt!
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            guard micActiveAt == activeSince else {
                logger.info("Mic state changed during debounce, aborting")
                return
            }

            guard settings.adHocMeetingDetectionEnabled else {
                logger.info("Detection disabled, skipping")
                return
            }
            guard recordingController.state != .recording else {
                logger.info("Already recording, skipping detection")
                return
            }

            let app = scanForMeetingApp()
            logger.info("Scan result: \(app?.name ?? "no meeting app found")")

            guard let app else {
                logger.info("No known meeting app running, skipping notification")
                return
            }

            if suppressedBundleIDs.contains(app.bundleID) {
                logger.info("\(app.name) is suppressed, skipping")
                return
            }

            if detectedApp == nil {
                detectedApp = app
                logger.info("Firing onMeetingDetected for \(app.name)")
                onMeetingDetected?(app)
            }
        } else {
            logger.info("Mic became inactive")
            micActiveAt = nil
            // Don't cancel the notification or clear detectedApp when mic goes
            // inactive — the user may have just muted. The notification persists
            // until the user interacts with it or it times out (60s).
        }
    }

    private func scanForMeetingApp() -> DetectedMeetingApp? {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard bundleID != Self.selfBundleID else { continue }

            if let known = Self.knownMeetingApps.first(where: { $0.bundleID == bundleID }) {
                let name = app.localizedName ?? known.name
                return DetectedMeetingApp(bundleID: bundleID, name: name)
            }
        }
        return nil
    }
}
