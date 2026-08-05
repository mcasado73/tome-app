import Foundation

enum TranscriptLoggerError: LocalizedError {
    case cannotCreateFile(String)
    case sessionAlreadyActive
    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let p): return "Cannot create transcript at \(p)"
        case .sessionAlreadyActive: return "A transcript session is already active"
        }
    }
}

/// Writes structured markdown transcripts to the vault.
actor TranscriptLogger {
    private var fileHandle: FileHandle?
    private var currentFilePath: URL?
    private var sessionStartTime: Date?
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []

    // Monotonic session IDs. Post-session work (diarization, frontmatter) runs
    // long enough that a new session can start meanwhile — every such call
    // carries the ID it was issued for so it can't write into the wrong file.
    private var sessionCounter: Int = 0
    private var currentSessionID: Int?

    // Retained from last session for post-session diarization and frontmatter finalization
    private var lastSessionID: Int?
    private var lastSessionFilePath: URL?
    private var lastSessionStartTime: Date?
    private var lastSpeakersDetected: Set<String> = []
    private var lastSessionContext: String = ""

    func startSession(sourceApp: String, vaultPath: String, sessionType: SessionType = .callCapture) throws {
        if fileHandle != nil {
            diagLog("[LOGGER] startSession called while previous session active — refusing")
            throw TranscriptLoggerError.sessionAlreadyActive
        }
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.sessionContext = ""
        self.utteranceBuffer = []

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = sessionStartTime!
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let dateStr = dateFmt.string(from: now)
        let timeStr = timeFmt.string(from: now)

        let isVoiceMemo = sessionType == .voiceMemo
        let fileLabel = isVoiceMemo ? "Voice Memo" : "Call Recording"
        let noteType = isVoiceMemo ? "fleeting" : "meeting"
        let logTag = isVoiceMemo ? "log/voice" : "log/meeting"
        let sourceTag = isVoiceMemo ? "source/voice" : "source/meeting"

        let filename = "\(fileFmt.string(from: now)) \(fileLabel).md"
        currentFilePath = directory.appendingPathComponent(filename)

        let content = """
---
type: \(noteType)
created: "\(dateStr)"
time: "\(timeStr)"
duration: "00:00"
source_app: "\(sourceApp)"
source_file: "\(filename)"
attendees: []
context: ""
tags:
  - \(logTag)
  - status/inbox
  - \(sourceTag)
  - source/tome
---

# \(fileLabel) — \(dateStr) \(timeStr)

**Duration:** 00:00 | **Speakers:** 0

---

## Context



---

## Transcript

"""

        let created = FileManager.default.createFile(atPath: currentFilePath!.path, contents: content.data(using: .utf8))
        guard created else { throw TranscriptLoggerError.cannotCreateFile(currentFilePath!.path) }
        fileHandle = try FileHandle(forWritingTo: currentFilePath!)
        fileHandle?.seekToEndOfFile()

        sessionCounter += 1
        currentSessionID = sessionCounter
    }

    func append(speaker: String, text: String, timestamp: Date) {
        let label = labelForSpeaker(speaker)
        speakersDetected.insert(label)
        utteranceBuffer.append((speaker: label, text: text, timestamp: timestamp))
        flushBuffer()  // Flush every utterance for crash safety
    }

    /// Periodic flush — call from a timer or at intervals
    func flushIfNeeded() {
        if !utteranceBuffer.isEmpty {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard let fileHandle, !utteranceBuffer.isEmpty else { return }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var lines = ""
        for entry in utteranceBuffer {
            lines += "**\(entry.speaker)** (\(timeFmt.string(from: entry.timestamp)))\n"
            lines += "\(entry.text)\n\n"
        }

        if let data = lines.data(using: .utf8) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }

        utteranceBuffer.removeAll()
    }

    func updateContext(_ text: String) {
        sessionContext = text
        guard let filePath = currentFilePath else { return }

        // Flush any buffered utterances first
        flushBuffer()
        try? fileHandle?.close()
        fileHandle = nil

        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Update frontmatter context field
        if let range = content.range(of: #"context: ".*""#, options: .regularExpression) {
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            content.replaceSubrange(range, with: "context: \"\(escaped)\"")
        }

        // Update ## Context body section
        if let contextStart = content.range(of: "## Context\n"),
           let contextEnd = content.range(of: "\n---\n\n## Transcript", range: contextStart.upperBound..<content.endIndex) {
            let replaceRange = contextStart.upperBound..<contextEnd.lowerBound
            content.replaceSubrange(replaceRange, with: "\n\(text)\n")
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: filePath)
        try? FileManager.default.moveItem(at: tmpPath, to: filePath)

        // Reopen file handle
        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    /// Closes the transcript and returns the ID of the session just ended, to be
    /// passed to `rewriteWithDiarization` / `collapseUnattributedSpeakers` /
    /// `finalizeFrontmatter`. Returns nil when there was no active session — a
    /// duplicated stop must not clear the retained state that post-session work
    /// still needs.
    func endSession() -> Int? {
        guard let sessionID = currentSessionID else {
            diagLog("[LOGGER] endSession called with no active session — ignoring")
            return nil
        }

        // Flush remaining buffer
        flushBuffer()

        // Close file handle immediately so next session can start
        try? fileHandle?.close()
        fileHandle = nil

        // Retain for post-session diarization and frontmatter finalization
        lastSessionID = sessionID
        lastSessionFilePath = currentFilePath
        lastSessionStartTime = sessionStartTime
        lastSpeakersDetected = speakersDetected
        lastSessionContext = sessionContext

        // Reset state immediately so next session can start
        currentSessionID = nil
        currentFilePath = nil
        sessionStartTime = nil
        speakersDetected = []
        sessionContext = ""

        // Frontmatter rewrite is NOT called here — caller must call
        // finalizeFrontmatter() AFTER diarization completes to avoid race.
        return sessionID
    }

    /// Call AFTER diarization is complete. Rewrites frontmatter with correct
    /// duration, speaker count, attendees, and optionally renames the file.
    @discardableResult
    func finalizeFrontmatter(sessionID: Int) async -> URL? {
        guard sessionID == lastSessionID else {
            diagLog("[LOGGER] finalizeFrontmatter for stale session \(sessionID) — ignoring")
            return nil
        }
        guard let filePath = lastSessionFilePath,
              let startTime = lastSessionStartTime else { return nil }

        await Self.rewriteFrontmatter(
            filePath: filePath,
            startTime: startTime,
            speakers: lastSpeakersDetected,
            context: lastSessionContext
        )

        // Update lastSessionFilePath if the file was renamed
        if !lastSessionContext.isEmpty {
            let truncated = String(lastSessionContext.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)
            lastSessionFilePath = newPath
        }

        let savedPath = lastSessionFilePath
        lastSessionID = nil
        lastSessionStartTime = nil
        lastSpeakersDetected = []
        lastSessionContext = ""
        return savedPath
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        speakers: Set<String>,
        context: String
    ) async {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Calculate duration
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        // Build attendees array
        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = sortedSpeakers.isEmpty ? "[]" : "[\"\(sortedSpeakers.joined(separator: "\", \""))\"]"

        // Update frontmatter fields (regex to handle already-rewritten values)
        if let range = content.range(of: #"duration: "\d{2}:\d{2}""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        }
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        // Update header line (regex to handle already-rewritten values)
        if let range = content.range(of: #"\*\*Duration:\*\* \d{2}:\d{2} \| \*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Duration:** \(durationStr) | **Speakers:** \(speakers.count)")
        }

        // Context-based file rename
        var finalPath = filePath
        if !context.isEmpty {
            let truncated = String(context.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            // Update source_file in content
            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)

        if finalPath != filePath {
            // Rename: remove old, move tmp to new name
            try? FileManager.default.removeItem(at: filePath)
            try? FileManager.default.moveItem(at: tmpPath, to: finalPath)
        } else {
            try? FileManager.default.removeItem(at: filePath)
            try? FileManager.default.moveItem(at: tmpPath, to: filePath)
        }
    }

    /// Rewrite the transcript file, replacing the live "Them" labels with diarized
    /// speaker IDs. Lines the diarizer can't account for are left as "Them", so
    /// the transcript shows its real coverage instead of hiding gaps behind a
    /// plausible-looking speaker number.
    func rewriteWithDiarization(_ diarization: PostSessionDiarization, sessionID: Int) {
        guard sessionID == lastSessionID else {
            diagLog("[DIARIZE] rewrite for stale session \(sessionID) — ignoring")
            return
        }
        guard let filePath = lastSessionFilePath else { return }
        let segments = diarization.segments
        guard !segments.isEmpty else { return }
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Build a map of unique diarization speaker IDs → friendly labels (Speaker 2, 3, etc.)
        var diarSpeakerMap: [String: String] = [:]
        var nextSpeakerNum = 2
        for seg in segments where diarSpeakerMap[seg.speakerId] == nil {
            diarSpeakerMap[seg.speakerId] = "Speaker \(nextSpeakerNum)"
            nextSpeakerNum += 1
        }

        // Segment times are relative to the first buffered audio sample, which
        // lands seconds *after* the session starts (models load first, then
        // ScreenCaptureKit warms up). Anchoring to the session start instead
        // would shift every attribution by that gap.
        let anchorSeconds = Self.secondsSinceMidnight(diarization.audioStartWallClock)

        // For each "**Them** (HH:mm:ss)" line, find the best matching diarization segment
        let pattern = #"\*\*Them\*\* \((\d{2}:\d{2}:\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        var appliedLabels: Set<String> = []
        var unattributed = 0

        // Process in reverse so range offsets stay valid
        for match in matches.reversed() {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            guard let offsetSeconds = Self.offsetSeconds(fromClockTime: timeStr, anchorSeconds: anchorSeconds) else {
                unattributed += 1
                continue
            }

            // Find best matching segment
            var bestMatch: String?
            for seg in segments {
                if offsetSeconds >= seg.startTime && offsetSeconds <= seg.endTime {
                    bestMatch = diarSpeakerMap[seg.speakerId]
                    break
                }
            }

            // Also try closest segment if no exact overlap
            if bestMatch == nil {
                var minDist: Float = .infinity
                for seg in segments {
                    let midpoint = (seg.startTime + seg.endTime) / 2
                    let dist = abs(offsetSeconds - midpoint)
                    if dist < minDist && dist < 10 { // within 10 seconds
                        minDist = dist
                        bestMatch = diarSpeakerMap[seg.speakerId]
                    }
                }
            }

            guard let label = bestMatch else {
                unattributed += 1
                continue
            }
            appliedLabels.insert(label)
            content = (content as NSString).replacingCharacters(
                in: match.range(at: 0),
                with: "**\(label)** (\(timeStr))"
            )
        }

        diagLog("[DIARIZE] Rewrote \(matches.count - unattributed)/\(matches.count) lines as \(appliedLabels.count) speakers, \(unattributed) left as Them")

        // Feed the diarized labels back so finalizeFrontmatter() — which runs
        // after this and rewrites the same fields — reports what's actually in
        // the body instead of the live You/Them pair.
        var speakers = appliedLabels
        if content.contains("**You** (") { speakers.insert("You") }
        if unattributed > 0 { speakers.insert("Them") }
        lastSpeakersDetected = speakers

        Self.writeAtomically(content, to: filePath, tmpName: ".tome_diar_tmp.md")
    }

    /// Fallback for sessions that were never diarized (voice memos) or where
    /// diarization produced nothing: collapse the live "Them" labels to
    /// "Speaker 2" so the transcript still reads as a two-party conversation.
    func collapseUnattributedSpeakers(sessionID: Int) {
        guard sessionID == lastSessionID else { return }
        guard let filePath = lastSessionFilePath,
              let content = try? String(contentsOf: filePath, encoding: .utf8),
              content.contains("**Them** (") else { return }

        let collapsed = content.replacingOccurrences(of: "**Them** (", with: "**Speaker 2** (")
        lastSpeakersDetected.remove("Them")
        lastSpeakersDetected.insert("Speaker 2")
        Self.writeAtomically(collapsed, to: filePath, tmpName: ".tome_diar_tmp.md")
    }

    /// Transcript timestamps carry no date, so both sides of the comparison are
    /// reduced to a time of day.
    private static func secondsSinceMidnight(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    private static func offsetSeconds(fromClockTime timeStr: String, anchorSeconds: Int) -> Float? {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var offset = parts[0] * 3600 + parts[1] * 60 + parts[2] - anchorSeconds
        if offset < -43_200 { offset += 86_400 }  // session ran across midnight
        return Float(offset)
    }

    private static func writeAtomically(_ content: String, to filePath: URL, tmpName: String) {
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(tmpName)
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: filePath)
        try? FileManager.default.moveItem(at: tmpPath, to: filePath)
    }

    /// The live writer can only tell "me" from "not me", so everything coming off
    /// the system audio stays "Them". Splitting it into Speaker 2/3/4 is
    /// `rewriteWithDiarization`'s job, and it looks for exactly this label —
    /// assigning speaker numbers here is what used to make it match nothing.
    private func labelForSpeaker(_ rawSpeaker: String) -> String {
        rawSpeaker.lowercased() == "you" ? "You" : "Them"
    }
}
