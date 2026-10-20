@preconcurrency import AVFoundation
import FluidAudio
import os

// VAD + ASR pipeline
final class StreamingTranscriber: @unchecked Sendable {
    private let asrProvider: ASRProvider
    private var asrManager: AsrManager?
    private var asrGeneration = 0
    /// Consecutive failed `transcribe` calls. Kept apart from VAD errors: VAD
    /// keeps succeeding while ASR is broken, and sharing one counter meant every
    /// good VAD chunk reset it, so a dead ASR never surfaced and the session
    /// just recorded nothing.
    private var asrFailures = 0
    private var asrReloads = 0
    private let vadManager: VadManager
    private let speaker: Speaker
    private let audioSource: AudioSource
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "io.gremble.tome", category: "StreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        asrProvider: ASRProvider,
        vadManager: VadManager,
        speaker: Speaker,
        audioSource: AudioSource = .microphone,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.asrProvider = asrProvider
        self.vadManager = vadManager
        self.speaker = speaker
        self.audioSource = audioSource
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Flush speech for transcription every ~30 seconds (480,000 samples at 16kHz).
    /// Longer chunks give Parakeet-TDT more context for better accuracy.
    private static let flushInterval = 480_000
    /// Consecutive errors after which the loop gives up.
    private static let maxConsecutiveErrors = 10
    /// ASR failures in a row before the models are reloaded off the ANE.
    private static let asrFailuresBeforeReload = 3
    /// Reloads attempted per transcriber before letting the loop fail.
    private static let maxAsrReloads = 2

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    /// Returns `true` if the loop exited due to fatal (repeated) errors.
    @discardableResult
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async -> Bool {
        (asrManager, asrGeneration) = await asrProvider.current()
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false
        var bufferCount = 0
        var consecutiveErrors = 0

        outerLoop: for await buffer in stream {
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                diagLog("[\(speaker.rawValue)] buffer #\(bufferCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) interleaved=\(fmt.isInterleaved) common=\(fmt.commonFormat.rawValue)")
            }

            guard let samples = extractSamples(buffer) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                diagLog("[\(speaker.rawValue)] samples: count=\(samples.count) max=\(maxVal)")
            }

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
                    consecutiveErrors = 0

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)
                            diagLog("[\(self.speaker.rawValue)] speech start")

                        case .speechEnd:
                            isSpeaking = false
                            diagLog("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")
                            if speechSamples.count > 8000 {
                                let segment = speechSamples
                                speechSamples.removeAll(keepingCapacity: true)
                                await transcribeSegment(segment)
                                if asrFailures > Self.maxConsecutiveErrors { break outerLoop }
                            } else {
                                speechSamples.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if isSpeaking {
                        speechSamples.append(contentsOf: chunk)

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                            if asrFailures > Self.maxConsecutiveErrors { break outerLoop }
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                    consecutiveErrors += 1
                    if consecutiveErrors > Self.maxConsecutiveErrors { break outerLoop }
                }
            }
        }

        if speechSamples.count > 8000 {
            await transcribeSegment(speechSamples)
        }

        if asrFailures > Self.maxConsecutiveErrors {
            diagLog("[\(speaker.rawValue)] giving up after \(asrFailures) consecutive ASR errors")
        }
        return consecutiveErrors > Self.maxConsecutiveErrors || asrFailures > Self.maxConsecutiveErrors
    }

    /// Transcribes one speech segment, updating `asrFailures`. After a few
    /// failures in a row the models are reloaded off the ANE and the segment is
    /// retried once, so the speech that exposed the failure isn't lost.
    private func transcribeSegment(_ samples: [Float], isRetry: Bool = false) async {
        guard let asrManager else { return }
        do {
            let result = try await asrManager.transcribe(samples, source: audioSource)
            asrFailures = 0
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            onFinal(text)
        } catch {
            asrFailures += 1
            log.error("ASR error: \(error.localizedDescription)")
            diagLog("[\(speaker.rawValue)] ASR error #\(asrFailures): \(error)")

            guard !isRetry else { return }
            // The other stream may already have reloaded the models; switch
            // to them right away instead of failing our way up to a reload.
            let latest = await asrProvider.current()
            if latest.generation > asrGeneration {
                (self.asrManager, asrGeneration) = latest
                await transcribeSegment(samples, isRetry: true)
                return
            }
            guard asrFailures >= Self.asrFailuresBeforeReload,
                  asrReloads < Self.maxAsrReloads
            else { return }
            asrReloads += 1
            guard let fresh = await asrProvider.recover(after: asrGeneration) else { return }
            (self.asrManager, asrGeneration) = fresh
            await transcribeSegment(samples, isRetry: true)
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Fast path: already Float32 at 16kHz (common for system audio from ScreenCaptureKit)
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                // Mono — direct copy
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else {
                // Multi-channel — take first channel only
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }
        }

        // Slow path: need to resample via AVAudioConverter
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
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
