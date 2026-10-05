# PieFlow for Mac

Personal voice dictation and meeting notes for macOS, modelled on Wispr Flow. Hold `fn`, speak, let go, and clean text lands wherever your cursor is.

## What it does

- **Dictation anywhere.** Hold `fn` (or Right Option, Right Command, Right Control) to talk. Double tap, or `fn` + space, for hands-free. Esc cancels.
- **Engines with fallback.** Grok speech to text (xAI), Groq Whisper Large v3 Turbo, and local whisper.cpp (offline, Metal accelerated). Order is configurable; a failed request falls through to the next engine.
- **AI cleanup.** Removes filler, applies self corrections ("Tuesday, no wait, Friday"), and follows a per app Style (formal, casual, very casual). Without a key, a rules engine does the basics.
- **Dictionary** biases transcription toward your names and jargon, and learns from edits you make in history.
- **Snippets** expand spoken triggers ("my email address") into saved text.
- **Transforms.** Select text in any app, press `⌥1` (Polish) or `⌥2` (Prompt Engineer), or add your own.
- **Notetaker.** Records your mic and the call's system audio (ScreenCaptureKit), transcribes live with You / Others labels, then writes a summary and action items.
- **Insights, Scratchpad, Flow Bar, menu bar item**, history with playback, retry and copy.

Everything is stored in `~/Library/Application Support/PieFlow`. Audio leaves the Mac only for the cloud engines you configure.

## Install

Open `dist/PieFlow-1.0.0.dmg`, drag PieFlow to Applications, and follow `docs/INSTALL.txt` for the one time Gatekeeper step (the app is ad hoc signed, not notarized).

## Build from source

Needs Command Line Tools (no full Xcode) and `brew install cmake`.

```bash
scripts/build.sh
```

That builds a universal (Apple silicon and Intel) app at `build/PieFlow.app` and the DMG in `dist/`. `scripts/build-whisper.sh` rebuilds the bundled `whisper-cli`.

## Check a build

```bash
build/PieFlow.app/Contents/MacOS/PieFlow --selftest
```

Prints PASS / SKIP / FAIL for fonts, data dir, whisper-cli, audio devices, mic capture, the event tap, every configured engine (using a synthesized speech clip) and AI cleanup.

```bash
PIEFLOW_HOME=/tmp/pf-demo build/PieFlow.app/Contents/MacOS/PieFlow --snapshot /tmp/pf-shots
```

Renders every screen to PNG with demo data in a throwaway data folder.
