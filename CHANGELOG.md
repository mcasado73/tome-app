# Changelog

## [Unreleased]

### Diarization
- Diarization is no longer discarded when another session ends while it runs. Only one ended session was retained, so a Teams mic flicker — a false session starting and stopping within seconds — or a short back-to-back call overwrote the meeting still being diarized, and its result was dropped as stale along with the speaker fallback and frontmatter finalization. Ended sessions are now retained per session ID until their post-session work completes
- Transcript duration is measured up to the stop instead of up to finalization, which waits for diarization and added a minute or more on long meetings
- Frontmatter finalization writes through its own temp file instead of the one shared with the live session's context updates

## [1.3.0] — 2026-09-17

### Auto-start on meeting detection
- Transcription starts and stops on its own when a conferencing app takes the microphone, watched through CoreAudio's per-process input state (Teams, Zoom, Webex, Slack, FaceTime, browsers)
- Detection follows the helper process that actually owns the mic — Teams captures in `com.microsoft.teams2.modulehost`, browsers in `.helper` processes — and falls back to matching the executable path for audio processes that report no bundle ID
- Stop debounce raised from 20s to 45s. Teams releases the input device when you mute, and again while moving from the join screen into the room, which was splitting single meetings across two transcripts and leaving an empty one behind for the join blip

### Audio capture reliability
- Tap format now comes from CoreAudio's `kAudioDevicePropertyNominalSampleRate` rather than `AVAudioInputNode.outputFormat(forBus:)`. The node keeps reporting the previous rate after a Bluetooth device renegotiates — AirPods run at 48kHz idle and drop to 24kHz once a call opens the mic — and `installTap` validates against the hardware, so the stale format was rejected and the session ran with no microphone at all
- Mic startup retries up to 4 times, re-reading live CoreAudio state each attempt, the last one letting AVFoundation resolve the bus format itself. Superseded attempts bail out instead of racing to assign the engine
- Mic watchdog runs for the whole session instead of checking once at 15s. `installTap` and `engine.start()` can both report success at the wrong sample rate and then deliver nothing at all, so a stalled tap is rebound, and the session is only aborted if the rebind fails to bring it back
- Default-input changes are debounced by 1s — switching to AirPods fires 8–16 notifications within the same second, and acting on the first tore the tap down mid-transition
- `installTap` wrapped in an Obj-C `@try/@catch` shim: AVFoundation raises NSExceptions during input-device transitions on macOS 26 that Swift cannot catch and that terminate the process via `abort()`
- Audio engine setup moved off MainActor, where an unwinding NSException poisoned the Swift Concurrency runtime and crashed the next button press, and the engine is recreated per session

### Transcript durability
- Transcripts are rebuilt automatically if the file is deleted while a session owns it. Writing through an open handle to an unlinked inode succeeds silently on Unix, so an external vault cleanup removing a just-created note cost an entire meeting with no error anywhere. Covered mid-session, at session end, and during the minutes post-session diarization runs
- Diarization results reach the transcript again. The live writer and the post-session rewriter disagreed on speaker labels, so every diarized session was computed and then discarded, landing in the vault as `You` + `Speaker 2`
- Sessions that recorded nothing and ran under a minute are discarded instead of leaving an empty note in the vault and an empty session file on disk
- Post-session steps log why they give up. They used to return silently, so a missing meeting left no trace to work back from

### Custom vocabulary
- Optional term list and correction map applied to finalized utterances, with fuzzy matching restricted to uppercase terms so ordinary words are not rewritten
- Fixed an auto-start lockup after the engine aborted its own session

### Diagnostics
- `diagLog` writes are serialized. The audio taps, the meeting detector and MainActor all logged concurrently through a non-atomic seek-and-write, interleaving partial lines and mangling roughly one line in 240
- Meeting detection logs only when the picture changes, down from a line every 2s — ~15k lines in two days, which rotated the 5MB log within hours and destroyed the history exactly when it was needed
- ScreenCaptureKit no longer logs ~3,600 dropped-frame errors an hour: a screen output is registered so its video frames have somewhere to go, and the frame interval is raised to 60s

## [1.2.2] — 2026-03-31
- Raised VAD threshold on system audio stream to reduce echo bleed during calls

## [1.2.0] — 2026-03-30
- Upgraded FluidAudio to latest (actor-based AsrManager) — fixes Swift 6 build failures on Xcode 26.4+
- Build script now fails on missing code signing identity instead of silently shipping unsigned
- Added Gatekeeper troubleshooting to README

## [1.1.0] — 2026-03-29
- Multilingual transcription: Parakeet-TDT v3, 25 European languages with auto-detection
- Pinned FluidAudio to 0.12.1

## [1.0.1] — 2026-03-28
- Spectrum visualizer replaces static waveform (reactive bars, peak hold, dynamic glow)
- Visual redesign: warm glass UI, chat-style transcript bubbles
- Pulsing recording indicator, silence countdown, keyboard shortcuts (⌘R, ⌘⇧R, ⌘.)
- Diarization progress messages during post-session processing
- Error visibility and save confirmation banner
- Session cleanup and async handling fixes

## [1.0.0] — 2026-03-24
- Initial release
- Local transcription via Parakeet-TDT v2 on Apple Silicon
- Call capture (mic + system audio) with per-app filtering
- Voice memo mode
- Speaker diarization
- Vault-native .md output with YAML frontmatter
- Sparkle auto-updates
