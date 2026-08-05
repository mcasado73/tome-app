import SwiftUI
import AppKit
import Combine

private let conferencingBundleIDs: [String: String] = [
    "com.microsoft.teams2": "Teams",
    "com.microsoft.teams": "Teams",
    "us.zoom.xos": "Zoom",
    "com.apple.FaceTime": "FaceTime",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.cisco.webexmeetingsapp": "Webex",
    "Cisco-Systems.Spark": "Webex",
    "com.google.Chrome": "Chrome",
    "company.thebrowser.Browser": "Arc",
    "com.apple.Safari": "Safari",
    "com.microsoft.edgemac": "Edge",
]

struct ContentView: View {
    @Bindable var settings: AppSettings
    let meetingDetector: MeetingDetector
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var audioLevel: Float = 0
    @State private var activeSessionType: SessionType?
    @State private var detectedAppName: String?
    @State private var silenceSeconds: Int = 0
    @State private var savedFileURL: URL?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var sessionElapsed: Int = 0
    /// Guards against re-entrant stopSession() while teardown is in flight.
    @State private var isStopping = false

    var body: some View {
        VStack(spacing: 0) {
            // Glass top bar
            topBar

            // Main content area
            if !isRunning && transcriptStore.utterances.isEmpty
                && transcriptStore.volatileYouText.isEmpty
                && transcriptStore.volatileThemText.isEmpty {
                emptyState
            } else {
                TranscriptView(
                    utterances: transcriptStore.utterances,
                    volatileYouText: transcriptStore.volatileYouText,
                    volatileThemText: transcriptStore.volatileThemText
                )
            }

            // Save banner
            if let url = savedFileURL, activeSessionType == nil {
                saveBanner(url: url)
            }

            // Waveform ribbon
            WaveformView(isRecording: isRunning, audioLevel: audioLevel)

            // Glass control bar
            ControlBar(
                isRecording: isRunning,
                activeSessionType: activeSessionType,
                audioLevel: audioLevel,
                detectedApp: detectedAppName,
                silenceSeconds: silenceSeconds,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                // F8: dispatch via main runloop to avoid the SwiftUI 26.4
                // `_ButtonGesture` → `MainActor.assumeIsolated` path that crashes
                // in `swift_task_isMainExecutorImpl`.
                onStartCallCapture: { DispatchQueue.main.async { startSession(type: .callCapture) } },
                onStartVoiceMemo:   { DispatchQueue.main.async { startSession(type: .voiceMemo) } },
                onStop:             { DispatchQueue.main.async { stopSession() } }
            )
        }
        .frame(minWidth: 280, maxWidth: 360, minHeight: 400)
        .background(Color.bg0)
        .preferredColorScheme(.dark)
        .overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            }
        }
        .onChange(of: showOnboarding) {
            if !showOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if transcriptionEngine == nil {
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
            }
        }
        // Audio level polling
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let engine = transcriptionEngine else {
                    if audioLevel != 0 { audioLevel = 0 }
                    continue
                }
                if engine.isRunning {
                    let newLevel = engine.audioLevel
                    if abs(newLevel - audioLevel) > 0.005 { audioLevel = newLevel }
                    if audioLevel > 0.01 {
                        silenceSeconds = 0
                    }
                } else if audioLevel != 0 {
                    audioLevel = 0
                }
            }
        }
        // Silence auto-stop + elapsed timer
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard isRunning else {
                    silenceSeconds = 0
                    continue
                }
                sessionElapsed += 1
                if audioLevel < 0.01 {
                    silenceSeconds += 1
                    if silenceSeconds >= 120 {
                        stopSession()
                    }
                }
            }
        }
        // Transcript buffer flush
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await transcriptLogger.flushIfNeeded()
            }
        }
        // Auto-start meeting detection
        .task {
            setupMeetingDetector()
            if settings.autoStartEnabled {
                meetingDetector.install()
            }
        }
        .onChange(of: settings.autoStartEnabled) {
            if settings.autoStartEnabled {
                meetingDetector.install()
            } else {
                meetingDetector.uninstall()
            }
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        // The engine can stop itself (watchdog aborting a zombie session, or a
        // fatal capture error) without ContentView knowing. When that happens
        // while a session is still logically active, finalize it so the
        // TranscriptLogger file handle is closed — otherwise the next auto-start
        // is refused forever and the app looks hung with a stuck recording.
        .onChange(of: transcriptionEngine?.isRunning) { _, running in
            if running == false, activeSessionType != nil {
                diagLog("[AUTO-STOP] engine stopped unexpectedly — finalizing session")
                stopSession()
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("TOME")
                .font(.system(size: 14, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color.fg1)

            Spacer()

            HStack(spacing: 10) {
                Text(topBarStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isRunning ? Color.fg1 : Color.fg2)

                if isRunning {
                    PulsingDot(size: 6)
                } else {
                    Circle()
                        .fill(Color.fg2)
                        .frame(width: 6, height: 6)
                        .opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.bg1.opacity(0.45))
        .overlay(Divider(), alignment: .bottom)
    }

    private var topBarStatus: String {
        if isRunning {
            return formatTime(sessionElapsed)
        } else if savedFileURL != nil {
            return "\(formatTime(sessionElapsed)) · Done"
        } else {
            return "Ready"
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 28))
                .foregroundStyle(Color.fg3)
            Text("No active session")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.fg2)
            Text("Start a call capture or voice memo\nto begin transcribing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.fg3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save Banner

    private func saveBanner(url: URL) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accent1.opacity(0.15))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accent1)
                )
            Text("Saved to \(url.lastPathComponent)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.fg1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Show in Finder") {
                DispatchQueue.main.async {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    savedFileURL = nil
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accent1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bg1.opacity(0.7))
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Helpers

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    private func formatTime(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    // MARK: - Meeting Detection

    private func setupMeetingDetector() {
        meetingDetector.onMeetingStarted = { bundleID, appName in
            guard !isRunning else { return }
            diagLog("[AUTO-START] starting session for \(appName)")
            startSession(appBundleID: bundleID, appName: appName)
        }
        meetingDetector.onMeetingStopped = {
            guard isRunning, activeSessionType == .callCapture else { return }
            diagLog("[AUTO-STOP] stopping session")
            stopSession()
        }
    }

    /// Auto-start variant: called by MeetingDetector with a known conferencing app.
    private func startSession(appBundleID: String, appName: String) {
        transcriptStore.clear()
        silenceSeconds = 0
        sessionElapsed = 0
        savedFileURL = nil
        bannerDismissTask?.cancel()

        Task {
            transcriptionEngine?.lastError = nil
            await sessionStore.startSession()
            do {
                try await transcriptLogger.startSession(
                    sourceApp: appName,
                    vaultPath: settings.vaultMeetingsPath,
                    sessionType: .callCapture
                )
            } catch {
                await sessionStore.endSession()
                transcriptionEngine?.lastError = error.localizedDescription
                return
            }
            activeSessionType = .callCapture
            detectedAppName = appName
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                appBundleID: appBundleID,
                vocabularyCorrector: makeVocabularyCorrector()
            )
        }
    }

    /// Builds a vocabulary corrector from the current settings, or nil if disabled/empty.
    private func makeVocabularyCorrector() -> VocabularyCorrector? {
        guard settings.vocabularyEnabled, let url = settings.vocabularyURL else { return nil }
        let set = VocabularyLoader.load(from: url)
        guard !set.isEmpty else { return nil }
        return VocabularyCorrector(terms: set.terms, corrections: set.corrections)
    }

    // MARK: - Actions

    private func startSession(type: SessionType) {
        transcriptStore.clear()
        silenceSeconds = 0
        sessionElapsed = 0
        savedFileURL = nil
        bannerDismissTask?.cancel()

        // Determine output folder and app bundle ID based on session type
        let outputPath: String
        let sourceApp: String
        var appBundleID: String?
        var resolvedAppName: String?

        switch type {
        case .callCapture:
            outputPath = settings.vaultMeetingsPath
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               let bundleID = frontApp.bundleIdentifier,
               let appName = conferencingBundleIDs[bundleID] {
                sourceApp = appName
                appBundleID = bundleID
                resolvedAppName = appName
            } else {
                sourceApp = "Call"
            }
        case .voiceMemo:
            outputPath = settings.vaultVoicePath
            sourceApp = "Voice Memo"
        }

        Task {
            transcriptionEngine?.lastError = nil
            await sessionStore.startSession()
            do {
                try await transcriptLogger.startSession(
                    sourceApp: sourceApp,
                    vaultPath: outputPath,
                    sessionType: type
                )
            } catch {
                await sessionStore.endSession()
                transcriptionEngine?.lastError = error.localizedDescription
                return
            }
            activeSessionType = type
            detectedAppName = resolvedAppName
            let corrector = makeVocabularyCorrector()
            if type == .callCapture {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID,
                    appBundleID: appBundleID,
                    vocabularyCorrector: corrector
                )
            } else {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID,
                    vocabularyCorrector: corrector
                )
            }
        }
    }

    private func stopSession() {
        // Three independent triggers can fire this (silence timeout, the meeting
        // detector, the engine stopping itself) and the teardown takes seconds.
        // A second entry used to clear the state that diarization still needed,
        // silently discarding the rewrite and the save banner.
        guard !isStopping else {
            diagLog("[STOP] stopSession already in progress — ignoring")
            return
        }
        isStopping = true

        let wasCallCapture = activeSessionType == .callCapture
        activeSessionType = nil
        detectedAppName = nil
        silenceSeconds = 0

        Task {
            await transcriptionEngine?.stop()
            await sessionStore.endSession()
            let endedSessionID = await transcriptLogger.endSession()

            // Teardown is done; release the guard here rather than after the
            // post-session work, which can run for minutes on a long recording
            // and would otherwise block the *next* session from ever closing.
            // From here on the session ID is what keeps late work off the wrong
            // file.
            isStopping = false
            guard let sessionID = endedSessionID else { return }

            var diarized = false
            if wasCallCapture {
                transcriptionEngine?.assetStatus = "Identifying speakers..."
                if let diarization = await transcriptionEngine?.runPostSessionDiarization(),
                   !diarization.segments.isEmpty {
                    transcriptionEngine?.assetStatus = "Rewriting transcript..."
                    await transcriptLogger.rewriteWithDiarization(diarization, sessionID: sessionID)
                    diarized = true
                }
            }
            if !diarized {
                // Nothing to attribute — don't leave the reader with bare "Them".
                await transcriptLogger.collapseUnattributedSpeakers(sessionID: sessionID)
            }

            transcriptionEngine?.assetStatus = "Finalizing..."
            let savedPath = await transcriptLogger.finalizeFrontmatter(sessionID: sessionID)
            transcriptionEngine?.assetStatus = "Ready"

            if activeSessionType == nil, let savedPath {
                savedFileURL = savedPath
                bannerDismissTask?.cancel()
                bannerDismissTask = Task {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { savedFileURL = nil }
                }
            }
        }
    }

    private func handleNewUtterance() {
        guard let last = transcriptStore.utterances.last else { return }

        silenceSeconds = 0

        let speakerName = last.speaker == .you ? "You" : "Them"
        Task {
            await transcriptLogger.append(
                speaker: speakerName,
                text: last.text,
                timestamp: last.timestamp
            )
        }

        Task {
            await sessionStore.appendRecord(SessionRecord(
                speaker: last.speaker,
                text: last.text,
                timestamp: last.timestamp
            ))
        }
    }
}
