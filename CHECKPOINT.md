# Checkpoint

Phase: 1.0.12 released (2026-11-21). main and tag v1.0.12 are at 15fc399; releases/latest returns v1.0.12 and the public download matches its checksum. The website is live at https://shivankoctupie.github.io/pieflow-mac/ (GitHub Pages, main branch, docs/ folder; every push to main redeploys it). The repository is public with its description, homepage and topics set.

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
- Search engines have not indexed the website yet; that takes days. Google Search Console (add the site, submit sitemap.xml) needs the owner's Google login. The page was sent to IndexNow (Bing and others) once; the key file is the 32 character .txt in docs/.
- The repository's social preview image can only be set in the GitHub web settings; docs/img/og.png is made for it.
- The app is not notarized, so every new user meets the "cannot verify" block on first launch. This is the biggest thing in the way of new users.
- Releases 1.0.0 to 1.0.11 and the git history still contain a whisper-cli with the build machine's home folder path in it. Left alone on purpose: removing it means rewriting history and deleting those releases.
- After a release, bump lastmod in docs/sitemap.xml only if the page itself changed. The page reads the version from the GitHub API, so it needs no edit per release.
- 1.0.11: the drag was proven with events sent to the panel, not with a real pointer on the installed app; that is a by-hand check.
- 1.0.11: on a bad connection more text comes from the local Base model, which is less accurate than Groq. A larger local model would help; nobody has measured how fast Small or Large v3 Turbo answer on this Mac.
- The network at the dev Mac lost 10 to 25% of packets to api.groq.com on 2026-11-19. A selftest that fails only on "stt groq" is that: run `ping -c 10 api.groq.com` before blaming the build.
