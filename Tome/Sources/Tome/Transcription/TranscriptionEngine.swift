import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

// Serializes diagLog writes. `seekToEndOfFile` + `write` is not atomic, and the
// audio tap callbacks, the meeting detector and the MainActor all log
// concurrently — which interleaved partial lines into the file and mangled
// roughly one line in 240.
private let diagLogLock = NSLock()

// Writes to /tmp/tome.log, rotating to /tmp/tome.log.1 once the file grows past
// ~5 MB (keeps one backup, so total on-disk footprint stays ~10 MB).
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/tome.log"
    let maxBytes: UInt64 = 5 * 1024 * 1024
    guard let data = line.data(using: .utf8) else { return }

    diagLogLock.lock()
    defer { diagLogLock.unlock() }

    if let fh = FileHandle(forWritingAtPath: path) {
        let size = fh.seekToEndOfFile()
        if size > maxBytes {
            fh.closeFile()
            let backup = path + ".1"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.moveItem(atPath: path, toPath: backup)
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

/// One diarized speech region. Times are seconds relative to the start of the
/// buffered WAV, not to the start of the session.
struct DiarizedSegment: Sendable {
    let speakerId: String
    let startTime: Float
    let endTime: Float
}

/// Diarization output plus the wall-clock instant its times are relative to.
struct PostSessionDiarization: Sendable {
    let segments: [DiarizedSegment]
    let audioStartWallClock: Date
}

/// Dual-stream mic + system audio transcription.
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    var assetStatus: String = "Ready"
    var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Combined audio level from mic and system for the UI meter.
    var audioLevel: Float { max(micCapture.audioLevel, systemCapture.audioLevel) }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?
    /// Polls mic tap liveness for as long as the session runs, so a tap that
    /// never starts — or stops delivering mid-session — gets rebound instead of
    /// silently costing us the "you" channel.
    private var watchdogTask: Task<Void, Never>?
    /// Coalesces the burst of `kAudioHardwarePropertyDefaultInputDevice`
    /// notifications Bluetooth devices emit — AirPods fire 8–16 within the same
    /// second — so the mic is torn down once, after the transition settles,
    /// rather than in the middle of it.
    private var micSwapDebounceTask: Task<Void, Never>?

    /// Interval between mic liveness checks.
    private static let watchdogInterval = Duration.seconds(15)
    /// How long the default-input burst is allowed to settle before we act.
    private static let micSwapDebounce = Duration.seconds(1)

    /// Shared FluidAudio instances
    private var asrProvider: ASRProvider?
    private var micVadManager: VadManager?
    private var sysVadManager: VadManager?

    /// Optional custom-vocabulary corrector applied to finalized utterances.
    private var vocabularyCorrector: VocabularyCorrector?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(locale: Locale, inputDeviceID: AudioDeviceID = 0, appBundleID: String? = nil, vocabularyCorrector: VocabularyCorrector? = nil) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else {
            diagLog("[ENGINE-0] start() skipped — already running")
            return
        }
        // Claim the slot synchronously, before any await, so a second concurrent
        // start() call sees isRunning=true and bails out.
        isRunning = true
        lastError = nil
        self.vocabularyCorrector = vocabularyCorrector
        if let vocabularyCorrector {
            diagLog("[ENGINE-VOCAB] enabled: \(vocabularyCorrector.termCount) terms, \(vocabularyCorrector.correctionCount) corrections")
        }

        guard await ensureMicrophonePermission() else {
            isRunning = false
            return
        }

        // 1. Load FluidAudio models
        assetStatus = "Downloading multilingual model (first run)..."
        diagLog("[ENGINE-1] loading FluidAudio ASR models...")
        do {
            self.asrProvider = try await ASRProvider.load()

            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let micVad = try await VadManager()
            self.micVadManager = micVad
            let sysVad = try await VadManager(config: VadConfig(defaultThreshold: 0.92))
            self.sysVadManager = sysVad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] FluidAudio models loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let asrProvider, let micVadManager, let sysVadManager else { return }

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        currentMicDeviceID = targetMicID ?? 0
        diagLog("[ENGINE-3] starting mic capture, targetMicID=\(String(describing: targetMicID))")
        let micStream = micCapture.bufferStream(deviceID: targetMicID)

        // 3. Start system audio capture
        diagLog("[ENGINE-4] starting system audio capture...")
        let sysStreams: SystemAudioCapture.CaptureStreams?
        do {
            sysStreams = try await systemCapture.bufferStream(appBundleID: appBundleID)
            diagLog("[ENGINE-5] system audio capture started OK")
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            sysStreams = nil
        }

        // 4. Start mic transcription
        let store = transcriptStore
        let corrector = vocabularyCorrector
        micTask = makeMicTask(stream: micStream, asrProvider: asrProvider, vadManager: micVadManager)

        // 5. Start system audio transcription
        if let sysStream = sysStreams?.systemAudio {
            let sysTranscriber = StreamingTranscriber(
                asrProvider: asrProvider,
                vadManager: sysVadManager,
                speaker: .them,
                audioSource: .system,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text in
                    let corrected = corrector?.apply(text) ?? text
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: corrected, speaker: .them))
                    }
                }
            )
            let reportSysError: @Sendable (String) -> Void = { [weak self] msg in
                Task { @MainActor in self?.lastError = msg }
            }
            sysTask = Task.detached {
                let hadFatalError = await sysTranscriber.run(stream: sysStream)
                if hadFatalError {
                    reportSysError("System audio transcription failed — restart session")
                }
            }
        }

        assetStatus = "Transcribing (Parakeet-TDT v3)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()

        startMicWatchdog()
    }

    // MARK: - Mic Pipeline

    /// Builds the mic `StreamingTranscriber` and the task that drives it.
    private func makeMicTask(
        stream: sending AsyncStream<AVAudioPCMBuffer>,
        asrProvider: ASRProvider,
        vadManager: VadManager
    ) -> Task<Void, Never> {
        let store = transcriptStore
        let corrector = vocabularyCorrector
        let micTranscriber = StreamingTranscriber(
            asrProvider: asrProvider,
            vadManager: vadManager,
            speaker: .you,
            audioSource: .microphone,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                let corrected = corrector?.apply(text) ?? text
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: corrected, speaker: .you))
                }
            }
        )
        let reportMicError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.lastError = msg }
        }
        return Task.detached {
            let hadFatalError = await micTranscriber.run(stream: stream)
            if hadFatalError {
                reportMicError("Mic transcription failed — restart session")
            }
        }
    }

    /// Tears down the current mic pipeline and rebuilds it on `deviceID`,
    /// leaving system audio and the loaded models untouched.
    private func rebindMic(to deviceID: AudioDeviceID) {
        guard let asrProvider, let micVadManager else { return }

        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = deviceID
        // 0 means "no explicit device": let MicCapture fall back to the system
        // default rather than asking CoreAudio to bind to device ID 0.
        let micStream = micCapture.bufferStream(deviceID: deviceID > 0 ? deviceID : nil)
        micTask = makeMicTask(stream: micStream, asrProvider: asrProvider, vadManager: micVadManager)
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) {
        guard isRunning, asrProvider != nil, micVadManager != nil else { return }

        // Only update user selection when explicitly changed (not from OS listener)
        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")
        rebindMic(to: targetMicID)
        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(targetMicID)")
    }

    // MARK: - Mic Watchdog

    /// Samples the mic tap counter for as long as the session runs.
    ///
    /// Two failures look identical from here and both cost us the "you"
    /// channel with no error anywhere: `installTap`/`engine.start` hanging
    /// inside CoreAudio at startup (the macOS 26.4 zombie session), and a tap
    /// that stops delivering mid-session after a Bluetooth input renegotiates
    /// its format. On the first stall we rebind the mic; only if that doesn't
    /// bring it back do we abort the session, which is the original behaviour.
    private func startMicWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            var lastCount = 0
            var stalls = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard !Task.isCancelled, let self, self.isRunning else { return }

                let count = self.micCapture.tapCallCount

                // Any movement counts as alive. `bufferStream` restarts the
                // counter, so a sample *below* the last one means the stream was
                // replaced — a device swap, or our own rebind below — rather
                // than that the tap died; take it as the new baseline and let
                // the next tick catch it if the replacement is dead too.
                if count != lastCount {
                    lastCount = count
                    stalls = 0
                    continue
                }

                stalls += 1
                let reason = count == 0 ? "no mic tap activity" : "mic tap stalled at #\(count)"

                guard stalls > 1 else {
                    diagLog("[ENGINE-WATCHDOG] \(reason) — rebinding mic")
                    if let captureError = self.micCapture.captureError {
                        diagLog("[ENGINE-WATCHDOG] last capture error: \(captureError)")
                    }
                    self.rebindMic(to: self.currentMicDeviceID)
                    // The rebind resets the tap counter.
                    lastCount = 0
                    continue
                }

                diagLog("[ENGINE-WATCHDOG] \(reason) after rebind — aborting zombie session")
                await self.stop()
                self.lastError = "Audio capture stalled — please restart the session"
                return
            }
        }
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                // User has "System Default" selected — follow the OS default
                self.scheduleMicSwap(inputDeviceID: 0)
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    /// Defers a device-driven mic swap, restarting the timer on every further
    /// notification in the burst. A switch to AirPods emits a dozen of these
    /// within the same second, and acting on the first one tears the tap down
    /// while CoreAudio is still renegotiating the hardware format.
    private func scheduleMicSwap(inputDeviceID: AudioDeviceID) {
        micSwapDebounceTask?.cancel()
        micSwapDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.micSwapDebounce)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.restartMic(inputDeviceID: inputDeviceID)
        }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
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

    func stop() async {
        lastError = nil
        removeDefaultDeviceListener()
        watchdogTask?.cancel()
        watchdogTask = nil
        micSwapDebounceTask?.cancel()
        micSwapDebounceTask = nil
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        await systemCapture.stop()
        micCapture.stop()
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
    }

    /// Run offline diarization on the buffered system audio.
    /// Returns the speaker segments and their wall-clock anchor, or nil if no
    /// audio was buffered or diarization failed.
    nonisolated func runPostSessionDiarization() async -> PostSessionDiarization? {
        // Detach before the first await: an auto-started session could otherwise
        // replace the buffer path — or delete the file — while we diarize.
        guard let audio = systemCapture.detachBuffer() else {
            diagLog("[DIARIZE] No buffered system audio file found")
            return nil
        }

        diagLog("[DIARIZE] Starting post-session diarization on \(audio.url.lastPathComponent)")

        do {
            let diarizer = OfflineDiarizerManager()

            diagLog("[DIARIZE] Preparing diarization models...")
            try await diarizer.prepareModels()

            diagLog("[DIARIZE] Processing audio...")
            let result = try await diarizer.process(audio.url)

            let segments = result.segments.map { seg in
                DiarizedSegment(
                    speakerId: seg.speakerId,
                    startTime: seg.startTimeSeconds,
                    endTime: seg.endTimeSeconds
                )
            }
            diagLog("[DIARIZE] Found \(segments.count) segments, \(Set(segments.map(\.speakerId)).count) speakers")

            systemCapture.removeBuffer(audio)
            return PostSessionDiarization(segments: segments, audioStartWallClock: audio.startWallClock)
        } catch {
            diagLog("[DIARIZE] Failed: \(error.localizedDescription)")
            systemCapture.removeBuffer(audio)
            return nil
        }
    }
}
