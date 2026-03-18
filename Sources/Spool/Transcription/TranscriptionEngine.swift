import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import Observation

@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    var onUtterance: (@Sendable (Utterance) -> Void)?
    var onPartial: (@Sendable (Speaker, String) -> Void)?

    func warmUpSystemAudioPermission() async {
        do {
            try await systemCapture.preflightPermission()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func currentPermissionMessage() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
        default:
            break
        }

        return nil
    }

    func requestPermissionsIfNeeded() async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                return "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
            }
        case .denied, .restricted:
            return "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
        @unknown default:
            return "Unable to verify microphone permission."
        }
        return nil
    }

    func start(locale: Locale) async {
        guard !isRunning else { return }
        lastError = nil

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        do {
            assetStatus = "Loading transcription models..."
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let asr = AsrManager(config: .default)
            try await asr.initialize(models: models)
            let vad = try await VadManager()

            asrManager = asr
            vadManager = vad
        } catch {
            lastError = "Failed to load transcription models: \(error.localizedDescription)"
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let asrManager, let vadManager else { return }

        let micDeviceID = MicCapture.defaultInputDeviceID()
        let micStream = micCapture.bufferStream(deviceID: micDeviceID)

        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { [weak self] text in
                Task { @MainActor in
                    self?.onPartial?(.you, text)
                }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in
                    self?.onUtterance?(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        do {
            let sysStream = try await systemCapture.bufferStream().systemAudio
            let sysTranscriber = StreamingTranscriber(
                asrManager: asrManager,
                vadManager: vadManager,
                speaker: .them,
                onPartial: { [weak self] text in
                    Task { @MainActor in
                        self?.onPartial?(.them, text)
                    }
                },
                onFinal: { [weak self] text in
                    Task { @MainActor in
                        self?.onUtterance?(Utterance(text: text, speaker: .them))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStream)
            }
        } catch {
            lastError = "System audio capture unavailable: \(error.localizedDescription)"
        }

        assetStatus = "Transcribing"
    }

    func stop() async {
        micTask?.cancel()
        sysTask?.cancel()
        micTask = nil
        sysTask = nil
        await systemCapture.stop()
        micCapture.stop()
        isRunning = false
        assetStatus = "Ready"
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

}
