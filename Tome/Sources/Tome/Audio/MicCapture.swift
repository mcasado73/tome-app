@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MicCaptureShim
import os

final class MicCapture: @unchecked Sendable {
    /// Recreated on every `bufferStream` call. Reusing the same AVAudioEngine
    /// across sessions on macOS 26.4 causes `installTap` to raise NSException
    /// intermittently, which terminates the process (see the 21-may crash
    /// dump: `AVAudioEngineImpl::InstallTapOnNode` → `objc_exception_throw`).
    private var engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()
    private let _tapCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    /// Number of tap callbacks delivered since the last `bufferStream` call.
    /// The engine watchdog uses this to detect a stalled startup (e.g. when
    /// `installTap` or `engine.start` hangs inside CoreAudio).
    var tapCallCount: Int { _tapCount.withLock { $0 } }

    /// How many times `bufferStream` re-reads the hardware format and retries
    /// the tap install before giving up, and how long it waits between tries.
    private static let maxStartAttempts = 4
    private static let retryDelay = Duration.milliseconds(300)

    /// Bumped by every `bufferStream` and `stop` call. Because a start now
    /// retries across ~1s, a second start (the watchdog rebinding the mic while
    /// the first one is still retrying) would otherwise leave two loops racing
    /// to assign `engine`. An attempt that no longer owns the current
    /// generation has been superseded and bails out instead.
    private let _generation = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    private var currentGeneration: Int { _generation.withLock { $0 } }

    @discardableResult
    private func bumpGeneration() -> Int {
        _generation.withLock { val -> Int in val += 1; return val }
    }

    func bufferStream(deviceID: AudioDeviceID? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error
        let tapCounter = _tapCount
        let generation = bumpGeneration()

        // Reset the tap counter so the engine watchdog can detect "no activity
        // since this start" cleanly.
        tapCounter.withLock { $0 = 0 }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        // Run all engine setup off the caller thread. The caller is usually on
        // MainActor and the CoreAudio APIs below (`installTap`, `engine.start`)
        // can hang or throw NSException on macOS 26.4 with certain device
        // transitions. An NSException unwinding on MainActor poisons the Swift
        // Concurrency runtime and crashes the next `_ButtonGesture` press.
        Task.detached { [weak self] in
            guard let self else { continuation.finish(); return }

            errorHolder.value = nil

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // Bluetooth inputs renegotiate their hardware sample rate when a
            // conferencing app opens the mic — AirPods run at 48kHz idle and
            // drop to 24kHz in hands-free mode — which is exactly the moment we
            // start a session. The format read from `inputNode` can therefore be
            // stale by the time `installTap` validates it, and AVAudioEngine
            // rejects the tap with "Failed to create tap due to format
            // mismatch", leaving the session with no mic at all. Re-read the
            // live format on every attempt and retry so the renegotiation has
            // time to settle.
            var lastFailure = "unknown"

            for attempt in 1...Self.maxStartAttempts {
                if attempt > 1 {
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !Task.isCancelled else { continuation.finish(); return }
                    diagLog("[MIC-RETRY] attempt \(attempt)/\(Self.maxStartAttempts) after: \(lastFailure)")
                }

                guard self.currentGeneration == generation else {
                    diagLog("[MIC-SUPERSEDED] abandoning start #\(generation) at attempt \(attempt)")
                    continuation.finish()
                    return
                }

                // Replace the AVAudioEngine instance on every attempt. See the
                // comment on the `engine` property — and a failed attempt can
                // leave the engine half-configured anyway.
                self.engine = AVAudioEngine()

                guard let failure = self.installAndStart(
                    deviceID: deviceID,
                    attempt: attempt,
                    level: level,
                    tapCounter: tapCounter,
                    continuation: continuation
                ) else {
                    errorHolder.value = nil
                    return
                }

                lastFailure = failure
            }

            diagLog("[MIC-START-FAIL] giving up after \(Self.maxStartAttempts) attempts: \(lastFailure)")
            errorHolder.value = lastFailure
            continuation.finish()
        }

        return stream
    }

    /// One attempt at binding `engine` to `deviceID`, installing the tap and
    /// starting the engine. Returns `nil` on success, or the failure reason.
    /// Every step re-reads live CoreAudio state, so the caller can simply retry.
    private func installAndStart(
        deviceID: AudioDeviceID?,
        attempt: Int,
        level: AudioLevel,
        tapCounter: OSAllocatedUnfairLock<Int>,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) -> String? {
        // Set input device before accessing inputNode format
        if let id = deviceID {
            guard let audioUnit = self.engine.inputNode.audioUnit else {
                let msg = "Input node has no audio unit"
                diagLog("[MIC-2-FAIL] \(msg)")
                return msg
            }
            var devID = id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            diagLog("[MIC-2] setInputDevice status=\(status) (0=ok)")
            guard status == noErr else {
                let msg = "Failed to set input device (OSStatus \(status))"
                diagLog("[MIC-2-FAIL] \(msg)")
                return msg
            }
        } else {
            diagLog("[MIC-2] no deviceID, using system default")
        }

        let inputNode = self.engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let resolvedDeviceID = deviceID ?? Self.defaultInputDeviceID()
        let hardwareRate = resolvedDeviceID.flatMap { Self.nominalSampleRate(for: $0) }

        diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) hwRate=\(hardwareRate.map { "\($0)" } ?? "n/a") ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)")

        // Trust CoreAudio over the node. `outputFormat(forBus:)` keeps reporting
        // the previous rate for a while after a Bluetooth device renegotiates —
        // on AirPods it says 48kHz long after the hardware dropped to the 24kHz
        // hands-free rate — while `installTap` validates against the hardware
        // and rejects our stale format outright. Re-reading the node cannot fix
        // that: it lies just as consistently on a brand new engine.
        let tapRate = hardwareRate ?? format.sampleRate

        guard tapRate > 0 && format.channelCount > 0 else {
            let msg = "Invalid audio format: sr=\(tapRate) ch=\(format.channelCount)"
            diagLog("[MIC-3-FAIL] \(msg)")
            return msg
        }

        // Last resort: install with no format at all and let AVFoundation
        // resolve the bus format itself.
        let tapFormat: AVAudioFormat?
        if attempt >= Self.maxStartAttempts {
            tapFormat = nil
            diagLog("[MIC-4] tapFormat: nil (letting AVAudioEngine resolve the bus format)")
        } else {
            guard let resolved = AVAudioFormat(
                standardFormatWithSampleRate: tapRate,
                channels: format.channelCount
            ) else {
                let msg = "Failed to build tap format from input format"
                diagLog("[MIC-4-FAIL] \(msg)")
                return msg
            }
            tapFormat = resolved
            diagLog("[MIC-4] tapFormat: sr=\(resolved.sampleRate) ch=\(resolved.channelCount)")
        }

        // Defensive: a fresh engine should have no tap, but on some
        // device transitions the previous engine's tap can linger on the
        // shared HAL input node. removeTap is a no-op when none exists.
        inputNode.removeTap(onBus: 0)

        var installError: NSError?
        let installed = MCInstallTapOnNode(inputNode, 0, 4096, tapFormat, { buffer, _ in
            let count = tapCounter.withLock { val -> Int in val += 1; return val }
            let rms = Self.normalizedRMS(from: buffer)
            level.value = min(rms * 25, 1.0)

            if count <= 5 || count % 100 == 0 {
                diagLog("[MIC-6] tap #\(count): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
            }

            continuation.yield(buffer)
        }, &installError)

        guard installed else {
            let reason = installError?.localizedDescription ?? "unknown"
            let msg = "Failed to install audio tap: \(reason)"
            diagLog("[MIC-5-FAIL] \(msg)")
            return msg
        }

        diagLog("[MIC-5] tap installed, preparing engine...")

        do {
            self.engine.prepare()
            diagLog("[MIC-7] engine prepared, starting...")
            try self.engine.start()
            diagLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
            return nil
        } catch {
            let msg = "Mic failed: \(error.localizedDescription)"
            diagLog("[MIC-8-FAIL] \(msg)")
            // Drop the tap so the retry starts from a clean node.
            inputNode.removeTap(onBus: 0)
            return msg
        }
    }

    func stop() {
        // Supersede any start still retrying, so it doesn't resurrect the mic
        // right after we tear it down.
        bumpGeneration()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        _audioLevel.value = 0
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
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
                let s = sampleAt(frame, channel)
                sum += s * s
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr else { continue }

            result.append((id: deviceID, name: name as String))
        }

        return result
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        return status == noErr ? uid as String : nil
    }

    /// The device's real sample rate, straight from CoreAudio. This is the
    /// value `installTap` validates against — and the one
    /// `AVAudioInputNode.outputFormat(forBus:)` gets wrong after a Bluetooth
    /// device renegotiates.
    static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
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
}

// Thread-safe audio level
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe optional string
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
