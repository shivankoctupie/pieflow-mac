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
