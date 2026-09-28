# 0003 — `Playback/` folder

**Status:** Accepted · 2026-09-26

## Context
Playback marking and the clip player need an `AVPlayer`, but views must not contain AVFoundation logic. The spec's layout has no home for this.

## Decision
- `Playback/MarkingSession.swift` — player, transport, debounce, mark insert/undo
- `Playback/LoopingClipPlayer.swift` — `AVQueuePlayer` + `AVPlayerLooper`
- `Playback/PlayerSurface.swift` — the one UIKit view holding an `AVPlayerLayer`

## Consequences
Views only hold these objects and send intents. Step 6's `RecordingView` should follow the same pattern with `CaptureSessionController`.
