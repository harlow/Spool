@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class SystemAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "Spool.SystemAudioCapture")

    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var streamFormat: AudioStreamBasicDescription?

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    func preflightPermission() async throws {
        let resources = try createTapResources()
        try teardown(resources: resources)
    }

    func bufferStream() async throws -> CaptureStreams {
        let resources = try createTapResources()
        let audioFormat = resources.format

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.lock.withLock {
                self.continuation = continuation
                self.tap = resources.tap
                self.aggregateDevice = resources.aggregateDevice
                self.ioProcID = resources.ioProcID
                self.streamFormat = audioFormat
            }

            continuation.onTermination = { _ in
                Task {
                    await self.stop()
                }
            }
        }

        return CaptureStreams(systemAudio: stream)
    }

    func stop() async {
        let snapshot = lock.withLock { CaptureResources(tap: tap, aggregateDevice: aggregateDevice, ioProcID: ioProcID, format: streamFormat) }
        do {
            try teardown(resources: snapshot)
        } catch {
            // Best effort cleanup. Nothing else to do here.
        }

        lock.withLock {
            continuation?.finish()
            continuation = nil
            tap = nil
            aggregateDevice = nil
            ioProcID = nil
            streamFormat = nil
        }
    }

    private func createTapResources() throws -> CaptureResources {
        let system = AudioHardwareSystem.shared
        guard let outputDevice = try system.defaultOutputDevice else {
            throw CaptureError.noDefaultOutputDevice
        }

        let currentProcess = try system.process(for: getpid())
        let excludedProcessIDs = currentProcess.map { [$0.id] } ?? []

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessIDs)
        description.name = "Spool System Audio"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: 0) ?? .init(rawValue: 0)!

        guard let tap = try system.makeProcessTap(description: description) else {
            throw CaptureError.failedToCreateTap
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spool System Audio Device",
            kAudioAggregateDeviceUIDKey: "Spool.Aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: try outputDevice.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: try outputDevice.uid
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: try tap.uid
                ]
            ]
        ]

        guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
            try system.destroyProcessTap(tap)
            throw CaptureError.failedToCreateAggregateDevice
        }

        try aggregateDevice.setSubtaps([tap])
        try aggregateDevice.setClockSource(outputDevice)

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDevice.id,
            callbackQueue
        ) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handleInputData(inInputData, format: try? tap.format)
        }

        guard status == noErr, let ioProcID else {
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(tap)
            throw CaptureError.failedToCreateIOProc(status)
        }

        let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(tap)
            throw CaptureError.failedToStartDevice(startStatus)
        }

        return CaptureResources(
            tap: tap,
            aggregateDevice: aggregateDevice,
            ioProcID: ioProcID,
            format: try tap.format
        )
    }

    private func handleInputData(_ inInputData: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription?) {
        guard let format else { return }

        var mutableFormat = format
        guard let avFormat = AVAudioFormat(streamDescription: &mutableFormat) else { return }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let firstBuffer = audioBuffers.first, firstBuffer.mDataByteSize > 0 else { return }

        let bytesPerFrame = max(Int(format.mBytesPerFrame), 1)
        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount)
        else {
            return
        }

        pcmBuffer.frameLength = frameCount
        let outputBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        for index in 0..<min(audioBuffers.count, outputBuffers.count) {
            let input = audioBuffers[index]
            var output = outputBuffers[index]
            guard let inputData = input.mData, let outputData = output.mData else { continue }
            memcpy(outputData, inputData, min(Int(input.mDataByteSize), Int(output.mDataByteSize)))
            output.mDataByteSize = input.mDataByteSize
            outputBuffers[index] = output
        }

        _ = lock.withLock {
            continuation?.yield(pcmBuffer)
        }
    }

    private func teardown(resources: CaptureResources) throws {
        let system = AudioHardwareSystem.shared

        if let aggregateDevice = resources.aggregateDevice, let ioProcID = resources.ioProcID {
            AudioDeviceStop(aggregateDevice.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
        }

        if let aggregateDevice = resources.aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        if let tap = resources.tap {
            try? system.destroyProcessTap(tap)
        }
    }

    private struct CaptureResources {
        let tap: AudioHardwareTap?
        let aggregateDevice: AudioHardwareAggregateDevice?
        let ioProcID: AudioDeviceIOProcID?
        let format: AudioStreamBasicDescription?
    }

    enum CaptureError: LocalizedError {
        case noDefaultOutputDevice
        case failedToCreateTap
        case failedToCreateAggregateDevice
        case failedToCreateIOProc(OSStatus)
        case failedToStartDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noDefaultOutputDevice:
                return "No default output device is available for system audio capture."
            case .failedToCreateTap:
                return "Failed to create the system audio tap."
            case .failedToCreateAggregateDevice:
                return "Failed to create the aggregate device for system audio capture."
            case .failedToCreateIOProc(let status):
                return "Failed to create the system audio IO proc (\(status))."
            case .failedToStartDevice(let status):
                return "Failed to start the system audio device (\(status))."
            }
        }
    }
}
