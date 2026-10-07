# 0011 — Recording (step 6) and the footage-safety parts of step 7

**Status:** Accepted · 2026-10-07 — built and unit-tested; camera behaviour unverified until the device test.

## What's built
- `RecordingService` protocol + `CaptureSessionController` (`AVCaptureSession` + `AVCaptureMovieFileOutput`, never `AVAssetWriter`).
  1920×1080 at 60 fps (falls back to 30 fps), HEVC when available, back wide camera at 1×, audio on, stabilization off,
  `maxRecordedDuration = .invalid`, focus/exposure lock after a 3 s settle, Refocus button, rotation via `RotationCoordinator`.
- Mark offsets from `CACurrentMediaTime()` deltas measured from the moment the file actually started.
- Recording screen (landscape-locked, per spec and decision 0008): whole screen marks on touch-down; Refocus top-left; Undo
  bottom-left (5 s, same as playback); elapsed, mark count and thermal warning top-right; dims to near-black with only the
  elapsed time after 30 s idle, lowering brightness — taps still mark; screen stays awake throughout.
- Pre-flight: blocks under 8 GB free; warns on battery < 50% and not charging, phone already hot, Low Power Mode.
- After stopping: "Saved 1:32:05 · 14 marks", **Make N Clips** (the usual processing screen) or Done.
- "Record Game" in Add Game is enabled. In the Simulator it shows "This device has no camera…".

## Deviations / additions
- **Protocol** keeps the spec's `startRecording() -> URL`, `stopRecording()`, `mark()` and adds `prepare()`, `refocus()`,
  `shutdown()` and an `onUnexpectedFinish` callback (recordings that end on their own still get saved).
- **Stop is a dedicated hold-to-stop button** (1 s, with a progress ring) bottom-right, not a long-press anywhere — a long
  press anywhere would also place a mark on touch-down.
- **The `Game` is created the moment the file starts** (duration 0), and marks are saved as they're tapped, so a crash
  mid-game still has a record. Duration and size are filled in on stop.
- **Step 7 items built now** because the spec says not to ship recording without them: stop-and-save on interruption,
  on backgrounding, and below 1 GB free (polled every 60 s); idle timer reset on every exit; launch-time recovery
  (`StorageManager.recoverRecordings`) — zero-length games get their real duration, and playable video files with no
  `Game` become "Recovered — <date>" games (source shown as Recorded; it can't tell an interrupted import apart).
  Unplayable files are never deleted. Still to do in step 7: verifying all of this on the device, and anything it finds.
- Recording writes to the **final filename, never `.partial`** — the launch sweep deletes partials.
- **Launch maintenance is skipped under XCTest**: unit tests run inside the app and share its Documents folder.
