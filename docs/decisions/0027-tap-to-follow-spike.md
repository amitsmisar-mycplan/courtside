# 0027 — Tap-to-follow tracking spike (debug builds only)

**Status:** Accepted as an experiment · 2026-11-11 (founder's "tap-to-follow tracking on one clip" request). Departs
from the spec's non-goals (computer vision), with the founder's explicit approval, for a feasibility test only.
Results: [docs/spikes/tap-to-follow.md](../spikes/tap-to-follow.md).

## Decision
- **Debug builds only.** Everything lives in `Courtside/Debug/` inside `#if DEBUG`. The only entry point is a "Debug"
  section in Settings, also inside `#if DEBUG`. Release and TestFlight builds don't include the screen, the
  tracker, or the menu item.
- **Apple Vision only:** `VNDetectHumanRectanglesRequest` finds people in the first frame and snaps the tap to a
  body. It uses the upper-body revision 1, because the full-body revision 2 found no one in sideline footage.
  `VNTrackObjectRequest` (accurate) follows the body at up to 30 frames a second, and restarts from the last box if
  Vision drops it. An optional mode re-seeds the tracker from the person detector when a detected body overlaps the
  tracked box (every 5th frame, or when the tracker's confidence drops below 0.5). No third-party code, no network.
- **No product changes:** no model, schema, `StorageManager`, export, or shipped-UI changes. The 9:16 follow view is
  only a preview: the playing clip is shifted and clipped on screen. `ClipExtractor` is untouched.
- **Results log:** JSON lines in `Application Support/Debug/tap-to-follow-log.jsonl`, shareable from the debug
  screen. It isn't a model file, so its URL is built in `TapToFollowLog`, not `StorageManager`. It never deletes
  anything. Entries hold the clip ID, verdict, failure note, scene, mode, processing time, and tracker statistics.
- **Simulator:** Vision has no inference context there, so the requests are pointed at the CPU in Simulator builds
  only.
- **Playback** reuses `LoopingClipPlayer` and `PlayerSurface` (decision 0003). The debug session adds a periodic time
  observer to draw the box.

## Outcome
No-go for this approach: 0 of 6 real clips checked kept the right player (see the spike report). A second spike on
tracking-by-detection with a correction tap is the suggested next step, if the feature is still wanted.

## If the spike is a go
The real feature would need a spec revision (computer vision is a non-goal). It would also need tracking on a
background queue, persisted tracks (a schema change with migration), and the follow crop as an export option through
`ClipExtractor` / `ExportComposer`. The debug code here is a reference, not a base to ship.
