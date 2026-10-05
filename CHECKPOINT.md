# Checkpoint

Phase: built and packaged (v1.0.0, 2026-10-05).

Done
- Native Swift app, all pages, onboarding, Flow Bar, menu bar item, Notetaker.
- `scripts/build.sh` produces universal `build/PieFlow.app` and `dist/PieFlow-1.0.0.dmg`.
- Packaged selftest from a copy pulled out of the DMG: SELFTEST OK (local whisper, fonts, whisper-cli, audio devices, rules engine).

Not yet verified (needs the human)
- Grok and Groq paths: no API keys on this machine during the build.
- fn hotkey, mic capture, paste, Notetaker system audio: need Microphone, Accessibility and Screen Recording granted to the installed app.

Next step
- Install from the DMG, run onboarding, add a key, then run `/Applications/PieFlow.app/Contents/MacOS/PieFlow --selftest` and expect every line PASS.
