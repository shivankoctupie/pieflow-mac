# Checkpoint

Phase: 1.0.10 built and verified locally on branch release/1.0.10 (2026-11-19). Not merged to main, no GitHub release yet.

Tests: --selftest, --bar-test, --duck-test, --pipeline-test, --watcher-test, --edit-test, --summarize-test, --drop-test, --mic-test, --aec-test, --update-test, --snapshot.

Done and verified in 1.0.10
- Flow Bar stays on screen when the app is hidden and with no Dock icon (`--bar-test`: BAR TEST PASS).
- Other apps keep their volume while PieFlow listens (`--duck-test`: 9.0 dB of ducking with the old behaviour, -0.5 dB with the fix).
- Dock icon follows the window; dictation starts with no Dock icon (`--bar-test`).
- Mic level no longer re-renders the window, saves encode off the main thread, history list is lazy.
- New icon in Assets/AppIcon.icns (regenerate with scripts/make-icon.swift).
- Packaged `--selftest`: SELFTEST OK.

Open
- Login launch without a window is not tested (needs a logout). If the window still opens at login, the Apple event check in `launchedAtLogin` is the place to look.
- How the Flow Bar motion feels is a by-eye check; pictures of each state come from `--bar-test <dir>`.
- Next step to ship: merge release/1.0.10 into main, tag v1.0.10, `gh release create` with the DMG and its .sha256.
