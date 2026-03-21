import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.fieldgrid.spool", category: "AudioActivityMonitor")

protocol AudioSignalSource: Sendable {
    var signals: AsyncStream<Bool> { get }
}

final class CoreAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "com.fieldgrid.spool.mic-listener")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false

    let signals: AsyncStream<Bool>

    init() {
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        let stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.physicalInputDeviceIDs()
            logger.info("Monitoring \(self.deviceIDs.count) input device(s)")

            for deviceID in self.deviceIDs {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
            }
        }
    }

    deinit {
        for deviceID in deviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        }
        continuation?.finish()
    }

    private static let listenerCallback: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.checkAndEmit()
        return kAudioHardwareNoError
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            if anyRunning != self.lastEmittedValue {
                self.lastEmittedValue = anyRunning
                logger.info("Audio device state changed: micActive=\(anyRunning)")
                self.continuation?.yield(anyRunning)
            }
        }
    }

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == kAudioHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == kAudioHardwareNoError else { return [] }

        return deviceIDs.filter { deviceID in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            return status == kAudioHardwareNoError && inputSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kAudioHardwareNoError && isRunning != 0
    }
}
