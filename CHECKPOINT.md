# Checkpoint

Phase: 1.0.12 built, tested and installed on the dev Mac (2026-11-21); README, docs/ website and the clean whisper-cli are written but not committed. Exact next step: commit, push, release v1.0.12 draft first (see Open), turn on GitHub Pages for main /docs, set the repository homepage to https://shivankoctupie.github.io/pieflow-mac/, then check the page and the download as a logged out visitor.

Tests: --selftest, --hedge-test, --bar-drag-test, --bar-test, --duck-test, --sys-meter with --duck-live or --vp-probe, --pipeline-test, --watcher-test, --edit-test, --summarize-test, --drop-test, --mic-test, --aec-test, --update-test, --snapshot.

Done and verified in 1.0.11
- A stalled or dead cloud connection no longer holds a dictation (`--hedge-test`: HEDGE TEST PASS; 1.84 s for the first stalled dictation, 0.93 s for the next, where the old code took 10 to 19 s).
- The Flow Bar can be dragged anywhere, stays there across dictations and restarts, and a click still starts a dictation (`--bar-drag-test`: BAR DRAG TEST PASS).
- Settings, System tab: "Flow Bar position" row with Reset (`--snapshot`: settings-system-end.png).
- Packaged `--selftest`: SELFTEST OK.

Done and verified in 1.0.10
- Flow Bar stays on screen when the app is hidden and with no Dock icon (`--bar-test`: BAR TEST PASS).
- Other apps keep their volume while PieFlow listens (`--duck-test`: 9.0 dB of ducking with the old behaviour, -0.5 dB with the fix).
- No dropouts around a dictation: one engine is stopped and restarted instead of rebuilt (`--sys-meter` with `--duck-live`: three dictations, marker tone flat within 1 dB, MIC REUSE PASS; with the old rebuild: 8 dB down at release, then near silence for a second). Echo cancellation holds on the reused engine (`--aec-test` PASS).
- Dock icon follows the window; dictation starts with no Dock icon (`--bar-test`).
- Mic level no longer re-renders the window, saves encode off the main thread, history list is lazy.
- New icon in Assets/AppIcon.icns (regenerate with scripts/make-icon.swift).
- Packaged `--selftest`: SELFTEST OK (the two Groq checks fail when api.groq.com is unreachable from this network, which happened for some minutes on 2026-11-19; rerun before blaming the build).

Open
- Login launch without a window is not tested (needs a logout). If the window still opens at login, the Apple event check in `launchedAtLogin` is the place to look.
- How the Flow Bar motion feels is a by-eye check; pictures of each state come from `--bar-test <dir>`.
- Machines still on 1.0.9 take the update through the in app updater; that path was not exercised for this release (the test Mac already ran 1.0.10).
- Not confirmed by ear yet: music staying untouched around a dictation on the released build.
- Machines on 1.0.10 or older take 1.0.11 through the in app updater; that path was not exercised for this release either.
- Uploading the DMG can fail on a bad connection ("HTTP 408: Upload body timed out"). Release as a draft first (`gh release create --draft`, then `gh release upload`, then `gh release edit --draft=false --latest`), so a release never goes public without its DMG.
- 1.0.11: the drag was proven with events sent to the panel, not with a real pointer on the installed app; that is a by-hand check.
- 1.0.11: on a bad connection more text comes from the local Base model, which is less accurate than Groq. A larger local model would help; nobody has measured how fast Small or Large v3 Turbo answer on this Mac.
- The network at the dev Mac lost 10 to 25% of packets to api.groq.com on 2026-11-19. A selftest that fails only on "stt groq" is that: run `ping -c 10 api.groq.com` before blaming the build.
