import CoreAudio
import AppKit
import Observation
import Darwin  // proc_pidpath

/// Monitors per-process audio input usage via CoreAudio's process objects to
/// detect when a known conferencing app (Teams, Zoom, etc.) starts/stops using
/// the microphone.
///
/// Unlike a global `IsRunningSomewhere` listener, this approach knows *which*
/// process is using the mic, so:
///   1. We can ignore Tome's own capture and detect when the conferencing app
///      itself releases the mic (fixing auto-stop).
///   2. We don't get false positives from unrelated apps (Voice Memos, Handy,
///      etc.) just because a conferencing app happens to be running.
@Observable
@MainActor
final class MeetingDetector {
    private(set) var detectedApp: (bundleID: String, name: String)?
    /// When the pending auto-stop will fire, while the conferencing app has
    /// released the mic and we're waiting out `stopDelay`. Drives the UI countdown.
    private(set) var pendingStopDeadline: Date?

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var perProcessListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var stopDebounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var isInstalled = false

    /// Polling interval used as a robust backup to per-process listeners.
    private let pollInterval: UInt64 = 2

    /// How long to wait after the conferencing app releases the mic before
    /// signaling stop (seconds). Absorbs brief mutes / device switches.
    ///
    /// Teams drops the input device whenever you mute, and again while moving
    /// from the join screen into the room. At 20s that split single meetings
    /// across two transcripts — and produced an empty one for the join blip.
    private let stopDelay: UInt64 = 45

    /// Last logged snapshot of who holds the mic, so the 2s poll only writes a
    /// line when the picture actually changes.
    private var lastInputSummary: String?

    /// Known conferencing bundle IDs, matched by *prefix* (see `conferencingName`)
    /// so helper processes that actually own the mic also count — e.g. the new
    /// Teams captures audio in `com.microsoft.teams2.modulehost`, and Chrome/Edge
    /// use `<bundle>.helper` processes.
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
        "org.mozilla.firefox": "Firefox",
    ]

    /// Fallback keywords matched against a process's executable path when the
    /// mic-owning process has no resolvable bundle identifier (observed for some
    /// helper/XPC audio processes that report `<no-bundle>` via NSRunningApplication).
    private let conferencingPathHints: [(needle: String, name: String)] = [
        ("microsoft teams", "Teams"),
        ("zoom", "Zoom"),
        ("firefox", "Firefox"),
        ("webex", "Webex"),
        ("cisco", "Webex"),
        ("slack", "Slack"),
        ("google chrome", "Chrome"),
        ("microsoft edge", "Edge"),
    ]

    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    var onMeetingStarted: ((String, String) -> Void)?  // (bundleID, appName)
    var onMeetingStopped: (() -> Void)?

    // MARK: - Lifecycle

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        diagLog("[MEETING-DETECT] install — own pid=\(ownPID)")

        attachListenersToAllProcesses()
        diagLog("[MEETING-DETECT] attached per-process listeners to \(perProcessListeners.count) audio processes")

        // Listen for process list changes (audio processes appearing/disappearing).
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.attachListenersToAllProcesses()
                self?.evaluate()
            }
        }
        processListListener = listBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            DispatchQueue.main,
            listBlock
        )

        // Initial state evaluation (e.g., user enables auto-start mid-meeting).
        evaluate()

        // Polling loop as a backup mechanism — per-process listeners are
        // unreliable in practice for some apps' helper audio processes.
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard !Task.isCancelled, let self else { return }
                self.attachListenersToAllProcesses()
                self.evaluate()
            }
        }
    }

    func uninstall() {
        guard isInstalled else { return }
        isInstalled = false
        stopDebounceTask?.cancel()
        stopDebounceTask = nil
        pendingStopDeadline = nil
        pollTask?.cancel()
        pollTask = nil

        if let block = processListListener {
            var listAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress,
                DispatchQueue.main,
                block
            )
            processListListener = nil
        }

        for (procID, block) in perProcessListeners {
            var addr = inputRunningAddress()
            AudioObjectRemovePropertyListenerBlock(procID, &addr, DispatchQueue.main, block)
        }
        perProcessListeners.removeAll()
        detectedApp = nil
    }

    // MARK: - Per-process listener management

    private func attachListenersToAllProcesses() {
        let current = Set(audioProcessObjects())
        let known = Set(perProcessListeners.keys)

        // Detach from processes that are no longer in the list.
        for stale in known.subtracting(current) {
            if let block = perProcessListeners.removeValue(forKey: stale) {
                var addr = inputRunningAddress()
                AudioObjectRemovePropertyListenerBlock(stale, &addr, DispatchQueue.main, block)
            }
        }

        // Attach to newly appearing processes.
        for procID in current.subtracting(known) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    self?.evaluate()
                }
            }
            var addr = inputRunningAddress()
            let status = AudioObjectAddPropertyListenerBlock(procID, &addr, DispatchQueue.main, block)
            if status == noErr {
                perProcessListeners[procID] = block
            }
        }
    }

    // MARK: - Core evaluation

    /// Returns the first conferencing app currently using audio input (excluding
    /// ourselves), if any.
    private func currentConferencingInputUser() -> (bundleID: String, name: String)? {
        var match: (bundleID: String, name: String)?
        var activeSummary: [String] = []
        for procID in audioProcessObjects() {
            guard processIsRunningInput(procID) else { continue }
            let pid = processPID(procID) ?? -1
            let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            let bid = app?.bundleIdentifier ?? "<no-bundle>"
            let name = app?.localizedName ?? "<no-name>"
            activeSummary.append("pid=\(pid) bid=\(bid) name=\(name)")
            if pid == ownPID { continue }
            if match == nil, let confName = conferencingName(bundleID: app?.bundleIdentifier, pid: pid) {
                match = (bid, confName)
            }
        }
        // This runs every 2s. Logging it unconditionally produced ~15k lines in
        // two days, which rotated the 5 MB diag log within hours and destroyed
        // the history right when it was needed. Log only when the picture
        // actually changes.
        let summary = "\(activeSummary.joined(separator: " | ")) → match=\(match?.name ?? "none")"
        if !activeSummary.isEmpty && summary != lastInputSummary {
            lastInputSummary = summary
            diagLog("[MEETING-DETECT] processes with input active: \(summary)")
        }
        return match
    }

    /// Resolves a conferencing app name for a mic-owning process, first by a
    /// prefix match on its bundle ID (so helper processes like Teams'
    /// `...modulehost` count), then by an executable-path keyword fallback for
    /// processes with no resolvable bundle identifier.
    private func conferencingName(bundleID: String?, pid: pid_t) -> String? {
        if let bundleID {
            for (prefix, name) in conferencingBundleIDs
            where bundleID == prefix || bundleID.hasPrefix(prefix + ".") {
                return name
            }
        }
        if let path = executablePath(forPID: pid)?.lowercased() {
            for hint in conferencingPathHints where path.contains(hint.needle) {
                return hint.name
            }
        }
        return nil
    }

    private func evaluate() {
        let current = currentConferencingInputUser()

        if let current {
            // A conferencing app is using the mic — cancel any pending stop.
            stopDebounceTask?.cancel()
            stopDebounceTask = nil
            pendingStopDeadline = nil

            if detectedApp == nil {
                diagLog("[MEETING-DETECT] \(current.name) (\(current.bundleID)) opened mic — starting")
                detectedApp = current
                onMeetingStarted?(current.bundleID, current.name)
            }
        } else {
            // No conferencing app currently has input running.
            guard let tracking = detectedApp, stopDebounceTask == nil else { return }
            diagLog("[MEETING-DETECT] \(tracking.name) released mic — debouncing \(stopDelay)s")
            let delay = stopDelay
            pendingStopDeadline = Date().addingTimeInterval(TimeInterval(delay))
            stopDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                if self.currentConferencingInputUser() == nil {
                    diagLog("[MEETING-DETECT] still released after \(delay)s — signaling stop")
                    self.detectedApp = nil
                    self.stopDebounceTask = nil
                    self.pendingStopDeadline = nil
                    self.onMeetingStopped?()
                }
            }
        }
    }

    // MARK: - CoreAudio helpers

    private func inputRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &dataSize, buf.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private func processPID(_ procID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(procID, &address, 0, nil, &size, &pid)
        return status == noErr && pid > 0 ? pid : nil
    }

    private func processIsRunningInput(_ procID: AudioObjectID) -> Bool {
        var address = inputRunningAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(procID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func bundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func executablePath(forPID pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
