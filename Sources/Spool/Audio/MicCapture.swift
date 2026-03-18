@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    func bufferStream(deviceID: AudioDeviceID? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            errorHolder.value = nil

            if let id = deviceID {
                let inputNode = self.engine.inputNode
                let audioUnit = inputNode.audioUnit!
                var devID = id
                _ = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }

            let inputNode = self.engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                errorHolder.value = "Invalid microphone audio format."
                continuation.finish()
                return
            }

            guard let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: format.channelCount
            ) else {
                errorHolder.value = "Failed to configure microphone format."
                continuation.finish()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)
                continuation.yield(buffer)
            }

            continuation.onTermination = { [engine] _ in
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }

            do {
                self.engine.prepare()
                try self.engine.start()
            } catch {
                errorHolder.value = "Mic failed: \(error.localizedDescription)"
                continuation.finish()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _audioLevel.value = 0
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(frameLength: frameLength, channelCount: channelCount) { frame, channel in
                if buffer.format.isInterleaved {
                    return channelData[0][(frame * channelCount) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(frameLength: frameLength, channelCount: channelCount) { frame, channel in
                if buffer.format.isInterleaved {
                    return Float(channelData[0][(frame * channelCount) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = sampleAt(frame, channel)
                sum += sample * sample
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }
}

final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
