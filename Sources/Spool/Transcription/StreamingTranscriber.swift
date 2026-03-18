@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

final class StreamingTranscriber: @unchecked Sendable {
    private let asrManager: AsrManager
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "Spool", category: "StreamingTranscriber")

    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        asrManager: AsrManager,
        vadManager: VadManager,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.asrManager = asrManager
        self.vadManager = vadManager
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    private static let vadChunkSize = 4096
    private static let flushInterval = 48_000

    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false

        for await buffer in stream {
            guard let samples = extractSamples(buffer) else { continue }
            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)

                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)
                        case .speechEnd:
                            isSpeaking = false
                            if speechSamples.count > 8000 {
                                let segment = speechSamples
                                speechSamples.removeAll(keepingCapacity: true)
                                await transcribeSegment(segment)
                            } else {
                                speechSamples.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if isSpeaking {
                        speechSamples.append(contentsOf: chunk)
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        }
                    }
                } catch {
                    log.error("VAD error for \(self.speaker.rawValue): \(error.localizedDescription)")
                }
            }
        }

        if speechSamples.count > 8000 {
            await transcribeSegment(speechSamples)
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let result = try await asrManager.transcribe(samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onPartial("")
            onFinal(text)
        } catch {
            log.error("ASR error for \(self.speaker.rawValue): \(error.localizedDescription)")
        }
    }

    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else {
            return nil
        }

        var error: NSError?
        let inputSource = ConverterInputSource(buffer: buffer)
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let nextBuffer = inputSource.take() {
                outStatus.pointee = .haveData
                return nextBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

private final class ConverterInputSource: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}
