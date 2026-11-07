# PieFlow for Mac: Architecture Decisions

## Shell and language

- **Native Swift + SwiftUI, built with SwiftPM.** A dictation tool lives on global key events, Accessibility paste and CoreAudio. Native code reaches all of them directly, starts instantly and ships as a 7 MB DMG. Electron (the Windows PieFlow) would add 150 MB and native addons for the same hooks.
- **Built against the macOS 26 SDK.** On the 27 SDK, SwiftUI's `@State` is a macro whose compiler plugin ships only with full Xcode, so Command Line Tools cannot build it. The 26 SDK compiles the same code cleanly. Deployment target is macOS 14.
- **Universal binary** (`--arch arm64 --arch x86_64`) so the DMG runs on any Mac from macOS 14.
- **Hand assembled .app bundle** in `scripts/build.sh` instead of an Xcode project. Fewer moving parts, one command.

## Hotkey

- **CGEventTap on flagsChanged + keyDown.** The only way to see `fn` (keycode 63, `maskSecondaryFn`) globally and to swallow Esc, space and `⌥digit` only while relevant. Needs Accessibility.
- **Gestures match Wispr:** hold to talk, release under 250 ms is ignored as an accidental tap, double tap or hold + space locks hands-free, press again to stop, Esc cancels.
- **macOS fn conflict is surfaced, not changed.** The app reads `AppleFnUsageType` and tells the user to set "Press fn key to: Do Nothing" with a button to Keyboard settings. Changing system settings for the user is out of bounds.

## Speech to text

- **"Grok" supported as xAI Grok STT (`POST https://api.x.ai/v1/stt`), and Groq is supported too** (`whisper-large-v3-turbo`, verbose_json for timestamps). The request said "grok"; both exist and both are fast, so both are first class and the order is user configurable.
- **Dictionary words feed the engines:** `keyterm` fields for xAI, the `prompt` for Groq and whisper.cpp.
- **Local fallback is whisper.cpp built static and universal with Metal embedded**, bundled in `Resources/bin`. No dylibs, no Python. Models download in app from the official Hugging Face repo. On an M5, base.en transcribes a 5 s clip in 0.22 s. The very first run compiles Metal shaders (about 14 s), so the app warms it up in the background at launch.
- **Silence guard:** clips under 0.3 s or with RMS under 0.002 never hit an engine; common Whisper hallucinations ("Thank you.", `[BLANK_AUDIO]`) are dropped.

## Cleanup

- **Rules first, LLM second.** Deterministic layer handles fillers, "new line", repeated words and dictionary replacements. The LLM pass (Groq `openai/gpt-oss-120b`, then xAI) runs with a 6 s budget and a sanity check that rejects output that drifted from the transcript (so a dictated question is never answered).
- **Long jobs (meeting summaries, voice report, transforms) may fall back to the local Claude Code CLI** when no cloud key exists.

## Insertion

- **Clipboard paste with restore.** Save pasteboard items, set text, post Cmd+V, restore after 600 ms unless the user copied something new. Marked `org.nspasteboard.TransientType` so clipboard managers skip it. Without Accessibility the text is left on the clipboard and the Flow Bar says so.

## Notetaker

- **Mic via AVAudioEngine, other side via ScreenCaptureKit audio** (`excludesCurrentProcessAudio`). Two streams are transcribed separately, which gives free "You" / "Others" labels without a diarization model.
- **Live transcript every 45 s**, tail flushed on stop, raw WAVs kept per meeting so it can be re-transcribed.
- Calendar integration skipped for v1; meetings are started from the page or the menu bar.

## Storage and privacy

- **JSON files in Application Support,** one per collection, debounced writes. Keys in `keys.json` with 0600 permissions rather than Keychain, because ad hoc signed apps get re-prompted for Keychain access on every rebuild.
- **Dictation audio auto-pruned** after 7 days by default. No telemetry, no accounts.

## Packaging

- **Ad hoc signature, no notarization** (no paid developer account). INSTALL.txt walks through "Open Anyway" or `xattr -dr com.apple.quarantine`. Consequence: macOS ties permissions to the binary hash, so after an update Accessibility may need re-granting.
- **DMG via hdiutil UDZO** with an Applications shortcut and a readme.

## UI

- Warm paper palette, Figtree for UI text and EB Garamond for display headings (both OFL, bundled), black pill toggles and buttons, orange accent, teal data colors, all taken from the reference screenshots. Dropdowns are custom so no system blue control breaks the theme.
- Team, billing, referral and MCP pages were left out: this is a single user personal tool.

## Fixes after first use (2026-10-05)

- **API key field lost focus every second.** The setup screen and System settings re-created their views on a 1 s timer to show live permission status, which discarded the focused text field. Permission status now lives in `PermissionState`, which publishes only on change. Key fields also got a Paste button. `--focus-test` reproduces the old failure and passes on the fix.
- **Groq retired `llama-3.3-70b-versatile`.** Default cleanup model is now `openai/gpt-oss-120b` (0.8 s, correct on the self-correction case where `gpt-oss-20b` over-trimmed). On any "model does not exist" error the app lists the key's models, switches to the best available and retries. The self test now fails if cleanup did not actually run.
- **Accessibility stayed off after "allowing" it.** Ad hoc signatures carry a per-build cdhash requirement, so every reinstall left a stale "PieFlow" row in Accessibility and Input Monitoring that looked on but matched nothing. Two fixes: the signature now pins the designated requirement to the bundle identifier, so grants survive updates (verified: reinstall over a running copy kept mic, screen and accessibility), and the Allow buttons run `tccutil reset <Service> app.pieflow.mac` before prompting so a stale row is replaced by a fresh one. Input Monitoring is shown as "Not needed" once the event tap is live, because an active tap works through Accessibility alone.
- **Speaker audio was being transcribed.** Dictating while music or a call played picked up the speakers. Fix: Apple voice processing on the input node (`setVoiceProcessingEnabled`), which cancels this Mac's own playback and suppresses noise. Two traps found while verifying: with voice processing on, the node reports a 7 channel format and `AVAudioConverter` turns it into pure silence, so the tap now asks for mono at the node rate; and the built in AGC amplified residual hiss until Whisper hallucinated words, so AGC is off. `--aec-test` plays a sentence through the speakers while recording and fails unless the isolated mic is live and the sentence is absent (verified: rms 0.0079 with the sentence transcribed before, 0.0013 and empty after). Setting "Isolate my voice" (on by default) in General. Other apps' volume is not ducked.
- **Auto update (1.0.2).** `Updater` asks `api.github.com/repos/shivankoctupie/pieflow-mac/releases/latest` 20 s after launch and every 6 hours, compares the tag with the running version, and offers a banner plus a menu bar item. Installing downloads the DMG, verifies it against the `.sha256` asset, runs `codesign --verify`, copies the bundle next to the install, strips quarantine, swaps with two renames (rolling back if the swap fails) and relaunches. No Sparkle: a single GitHub call is enough for a personal app and there is no feed to host. `--update-test` with `PIEFLOW_FAKE_VERSION` exercises the whole path against the live release.

## 1.0.3: headphones, calls, images, copy (2026-10-13)

- **Earbud dictations were empty or garbled.** 21 of 172 dictations produced nothing. The Bluetooth earbuds' mic is the system default: it runs over the headset profile at 16 kHz, opens the link lazily (0.5 s or more of silence, 40 percent of samples missing in a 3 s test), and voice processing drags playback down to the same profile. Policy now: with the default input on Bluetooth, capture from the built in mic; voice isolation only when the Mac's own speakers are the output. Microphone setting "Automatic" explains the choice; a pinned device still wins.
- **Capturing a non default device.** AVAudioEngine's input node accepted a device switch via `AudioUnitSetProperty` and delivered nothing; `setDeviceID` failed with -10868; a stale tap format threw an uncatchable NSException. The engine is now used only for the system default device (the only path with voice processing). Any specific device, and any Bluetooth device, goes through AVCaptureSession, which switches devices properly. The tap uses the node's native format and `process()` takes channel 0 itself (AVAudioConverter's channel mixing was the source of the earlier silence under voice processing). A watchdog falls back to the built in mic if a device stays silent for 1.2 s; `AVAudioEngineConfigurationChange` restarts capture without losing audio. `--mic-test [uid] [--seconds N]` logs device, format, sample count and leading silence; dropped dictations are logged with their numbers.
- **Calls start and stop Notetaker.** CoreAudio process objects (`kAudioProcessPropertyIsRunningInput`) say which app holds the mic. After 4 s of a known call app (Zoom, Teams, FaceTime, Slack, Webex, Discord, browsers for Meet, WhatsApp, Telegram) PieFlow asks, records automatically, or does nothing (setting); a recording started this way stops 20 s after that app releases the mic. No window title sniffing, no calendar. Verified end to end with a second PieFlow instance holding the mic for 8 s.
- **Scratchpad images.** Cmd+V with an image (and no text) on the clipboard, or a drop, stores a PNG under Application Support/PieFlow/notes and shows a thumbnail strip; click opens, right click copies or removes. Notes decode tolerantly so old notes without images still load.
- **Copy anything.** `.textSelection(.enabled)` at the root of the main window, settings, help and onboarding makes every Text selectable.
- **Instant start.** Building the microphone pipeline on each key press took 380 to 550 ms (capture session) before any audio flowed, and the pill only appeared after that. A standby pipeline is now prepared ahead of time (engine prepared or capture session configured, microphone not opened, so no indicator) and refreshed every 4 s when devices change; a press just switches it on. Measured 80 to 95 ms to first audio. The pill and the start sound now fire on the key press, before the mic opens.
- **Drag and drop into notes (1.0.4).** SwiftUI's `onDrop` on the note only caught drops on the margins: the NSTextView under `TextEditor` claims any drag over the text and would insert a file path. The note body is now an `NSTextView` subclass that accepts image files and raw image data on drop and on paste (`performDragOperation`, `paste`) and hands them to the note, so the global Cmd+V key monitor went away. Dropping an image on the Scratchpad list creates a new note. `--drop-test` checks the pasteboard reader against a file URL, raw image data and plain text.
- **Apple Voice Isolation (1.0.5).** On the earbud path there was no isolation at all, and voice processing is not available for a non default device. The real upgrade is Apple's system Mic Mode "Voice Isolation" (ML noise and background voice removal, the FaceTime one): macOS applies it to any app capturing through AVCaptureSession or voice processing, but only the user can select it, per app, from Control Center while the app holds the mic, and `AVCaptureDevice.showSystemUserInterface(.microphoneModes)` does nothing on this macOS (verified by screenshot). Settings > General > Apple Voice Isolation holds the mic for 40 s and tells the user to click the orange mic icon and pick Voice Isolation; the active mode shows live and is logged on every dictation (`micMode=`). The old toggle is now named "Cancel speaker audio", which is what it does.

## 1.0.6: speed, calls, long meetings, feedback, learning (2026-11-07)

- **Release to text was 1.4 s median.** Three changes: uploads are AAC (a 12 s clip is 40 KB instead of 384 KB, 81 ms to encode), the HTTPS connection to the provider is opened on the key press so the request at release skips DNS and TLS, and short dictations that are already clean (10 words or fewer, no fillers or corrections, capitalised, punctuated) skip the AI pass, which was 300 to 600 ms for nothing. Measured: 5 s clip 530 to 800 ms end to end, short clean sentence about 250 ms. Every dictation logs stt, cleanup and release to text timings.
- **Meet in Chrome never triggered Notetaker.** Chrome holds the mic from a helper process (`com.google.Chrome.helper`), and Safari and FaceTime were dropped by the `com.apple.` filter. Matching is now by prefix with an Apple allow list, and any unknown app holding the mic is logged once so the list can grow.
- **Long meetings.** Groq's free tier allows 8,000 tokens per minute, so summaries over about 9,000 characters go to the Claude CLI when installed (no limit, 23 s for a 40 minute meeting) or are written in pieces with pacing. The CLI fallback used to fail silently because the app's launchd PATH has no node; it now gets a real PATH. ScreenCaptureKit drops the other side's audio when the display sleeps ("Failed to find any displays"); the capture now reopens itself every 5 s until the meeting ends. A meeting interrupted by a quit keeps its transcript and is summarised at the next launch.
- **Buttons answered nothing.** A toast at the bottom of the window confirms copy, save, export, transforms and resets. Meeting pages have Copy summary and Copy transcript separately, plus Copy everything in the menu.
- **Learning from corrections in other apps.** After a paste, the focused field of the target app is read through Accessibility for 45 s. A single word the user changes inside the pasted text becomes a Dictionary entry (word plus misheard form), with a "Learned" flash in the Flow Bar. Only the focused field is read, nothing is stored but the word pair. `--edit-test` covers the detector.
- **Every dictation pasted twice (1.0.7).** Two PieFlow processes were running: a stray test copy launched from the build folder the day before, plus the installed app. Both listened to fn, both recorded, both pasted, each with its own transcription. A fresh launch now retires any other instance of the bundle id (terminate, then force), and the relaunch paths exit the process outright after flushing instead of asking AppKit to terminate, which can be refused and leave a stale copy. Cleanup moved to `qwen/qwen3.8-27b`: 0.25 s against 0.55 to 0.83 s for gpt-oss-120b on the same transcript, same output. Pipeline test: 370 to 445 ms from release to text on a 5 s clip.
- **Relaunch after update (1.0.8).** `open <app>` only activates a copy that is still running, so an update could install the new bundle and leave the old process in charge. Relaunch uses `open -n`, which starts a fresh instance; its launch guard retires the old one.
- **Silent microphone (1.0.9).** A process whose bundle was replaced on disk gets silence from the mic instead of audio (seen after an update, before the old copy was retired). The watchdogs now treat 1.2 to 1.5 s of pure zeros like no audio at all: discard the standby pipeline, rebuild, and keep recording.
