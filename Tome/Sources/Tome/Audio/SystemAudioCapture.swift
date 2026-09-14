@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    private let _stream = OSAllocatedUnfairLock<SCStream?>(uncheckedState: nil)
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _micContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _audioLevel = AudioLevel()

    var audioLevel: Float { _audioLevel.value }

    // Temp WAV for diarization
    private let _bufferFilePath = OSAllocatedUnfairLock<URL?>(uncheckedState: nil)

    /// Wall-clock instant of the first sample written to the buffer WAV. The
    /// diarizer reports segment times relative to the start of that file, which
    /// is *not* the start of the session: the models load first, then
    /// ScreenCaptureKit takes a moment to deliver its first callback. Whoever
    /// maps diarized segments onto transcript timestamps must anchor to this.
    private let _bufferStartWallClock = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)

    private let _audioFileWriter = OSAllocatedUnfairLock<AVAudioFile?>(uncheckedState: nil)

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    /// A finished recording handed off for diarization, with the anchor its
    /// segment times will be relative to.
    struct BufferedAudio: Sendable {
        let url: URL
        let startWallClock: Date
    }

    /// Start capturing system audio. Pass a bundle ID to filter to a specific app.
    func bufferStream(appBundleID: String? = nil) async throws -> CaptureStreams {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Build content filter — per-app if possible, otherwise all system audio
        let filter: SCContentFilter
        if let bundleID = appBundleID,
           let matchedApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            diagLog("[SYS-FILTER] Per-app filter: \(bundleID)")
            filter = SCContentFilter(display: display, including: [matchedApp], exceptingWindows: [])
        } else {
            if let bundleID = appBundleID {
                diagLog("[SYS-FILTER] App \(bundleID) not found in shareable content, falling back to all system audio")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        // Set up audio buffer file for post-session diarization. Drop any buffer
        // from a previous session that was never handed off (voice memos never
        // diarize) so temp WAVs don't pile up.
        if let stale = takeBufferPath() {
            try? FileManager.default.removeItem(at: stale)
        }
        let bufferURL = FileManager.default.temporaryDirectory.appendingPathComponent("tome_sys_audio_\(UUID().uuidString).wav")
        _bufferFilePath.withLock { $0 = bufferURL }
        _audioFileWriter.withLock { $0 = nil } // will be created on first audio callback

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000

        // Minimal video — we only want audio. ScreenCaptureKit always runs a
        // video stream, so the cheapest configuration is a 2x2 frame as rarely
        // as it will accept: at 1 fps this logged
        // "stream output NOT found. Dropping frame" 3,600 times an hour.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 60, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        // Register a screen output too. Without one, SCK treats every video
        // frame it produces as undeliverable and logs an error for it; our
        // handler discards non-audio buffers, so this just stops the noise.
        // Never fatal: losing the noise suppression must not cost us the audio.
        do {
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        } catch {
            diagLog("[SYS-FILTER] screen output not registered (\(error.localizedDescription)) — video frames will log drops")
        }

        let sysStream = AsyncStream<AVAudioPCMBuffer> { cont in
            self._sysContinuation.withLock { $0 = cont }
        }

        _stream.withLock { $0 = scStream }
        try await scStream.startCapture()

        return CaptureStreams(systemAudio: sysStream)
    }

    func stop() async {
        try? await _stream.withLock { $0 }?.stopCapture()
        _stream.withLock { $0 = nil }
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
        _audioFileWriter.withLock { $0 = nil } // closes the file
        _audioLevel.value = 0
    }

    /// Hand the buffered WAV to the caller, which becomes responsible for
    /// deleting it via `removeBuffer(_:)`. Detaching drops our reference, so a
    /// session starting while diarization runs can neither overwrite nor delete
    /// the file being processed.
    func detachBuffer() -> BufferedAudio? {
        let path = takeBufferPath()
        let startWallClock = _bufferStartWallClock.withLock { clock -> Date? in
            let value = clock
            clock = nil
            return value
        }
        guard let path else { return nil }
        // No wall clock means no audio callback ever fired: nothing to diarize.
        guard let startWallClock, FileManager.default.fileExists(atPath: path.path) else {
            try? FileManager.default.removeItem(at: path)
            return nil
        }
        return BufferedAudio(url: path, startWallClock: startWallClock)
    }

    /// Remove a buffered audio file after diarization is complete.
    func removeBuffer(_ audio: BufferedAudio) {
        try? FileManager.default.removeItem(at: audio.url)
    }

    private func takeBufferPath() -> URL? {
        _bufferFilePath.withLock { path -> URL? in
            let value = path
            path = nil
            return value
        }
    }

    // MARK: - SCStreamOutput

    private let _sampleCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              var asbd = formatDesc.audioStreamBasicDescription else { return }

        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // Update audio level for visualizer
        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.value = min(rms * 25, 1.0)

        // Diagnostic: log raw system audio levels periodically
        let count = _sampleCount.withLock { val -> Int in val += 1; return val }
        if count <= 5 || count % 200 == 0 {
            diagLog("[SYS-RAW] #\(count) frames=\(frameCount) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) rms=\(rms)")
        }

        // Buffer audio to disk for post-session diarization
        let sampleRate = asbd.mSampleRate
        _audioFileWriter.withLock { writer in
            if writer == nil, let bufferPath = self._bufferFilePath.withLock({ $0 }) {
                let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
                writer = try? AVAudioFile(forWriting: bufferPath, settings: wavFormat.settings)
                if writer != nil {
                    // t=0 of the diarizer's timeline.
                    self._bufferStartWallClock.withLock { $0 = Date() }
                }
            }
            try? writer?.write(from: pcmBuffer)
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("SystemAudioCapture: stream stopped with error: \(error)")
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channelData[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(frameLength))
    }

    enum CaptureError: Error {
        case noDisplay
    }
}
