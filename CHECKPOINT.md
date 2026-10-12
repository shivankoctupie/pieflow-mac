# Checkpoint

Phase: 1.0.3 shipped (2026-10-13).

Done and verified
- Bluetooth earbuds: automatic policy captures the built in mic via AVCaptureSession (48,122 samples / 3 s, zero leading silence). Pinned earbud mic also live via capture session.
- Meeting detection: auto start after 4 s of mic use by a call app, auto stop 20 s after release (verified with a second instance holding the mic).
- Instant start: standby mic pipeline, 80 to 95 ms to first audio, pill on key press.
- Note images render; selectable text everywhere; updater verified 1.0.1 to 1.0.2 and 0.9.0 to 1.0.1 (fake version), real unfaked update pending the 1.0.3 release.

Open
- Speaker path (AVAudioEngine + voice processing) after the process() rewrite: evidence from the format probe only (native tap on the VP node carries audio on all channels). Confirm from pieflow.log: a line `mic: engine ... isolation on` followed by `stt ok`. Or run `open -n -W build/PieFlow.app --args --aec-test` with Bluetooth off.
- Paste of an image into a note is tested by code review and the thumbnail render only; the Cmd+V monitor is a user-level check.
