# 0015 — Trim a clip after it's made

**Status:** Accepted · 2026-10-30 (founder's "trim a clip" spec)

## Decision
- **Trim screen replaces the "1 sec earlier / later" nudge** (0004) on the clip screen — one way to adjust a clip, not two.
  It shows the full game video around the clip: a preview that loops the chosen range, a strip of frames with start and
  end handles, the tap in yellow, the range, its length, and seconds before / after the tap.
- **Limits:** the start may reach 30 s before the tap and the end 15 s after, clamped to the start and end of the game
  video. Minimum length 2 s. A clip already wider than that (made under older rules) is never forced shorter — the
  limits widen to include it.
- **"Reset to Default"** puts back 10 s before / 3 s after the tap (the spec's fixed default, not the Settings pre/post
  roll), clamped to the video.
- **Storage — no schema change.** The spec says to store the clip as the tap plus start/end offsets. `Clip` already stores
  the tap (`markSeconds`) and the edges in game-video seconds; the offsets are exactly `mark − start` and `end − mark`
  (`secondsBeforeMark`, `secondsAfterMark`). Adding offset fields would duplicate that. Clips made before `markSeconds`
  existed infer the tap (3 s before the end, as in 0007) and get it stored on their first trim.
- **Save re-cuts through `ClipExtractor.trim`** (replacing `nudge`): same `export` path, HEVC Highest Quality, never
  passthrough, progress shown. One export at a time; the screen is blocked while it runs. Written to `.partial` first and
  then swapped in under the same filename, so the old file is replaced, never left behind, and a failed export keeps the
  old clip. The thumbnail is regenerated; a slow-mo version (cut from the old clip) is removed, and the screen says so.
- **Dragging never exports.** Handles only move the range and seek the preview (`TrimSession` in `Playback/`).
- **No full game video → no trimming.** Trim is disabled on the clip screen with a reason ("feature 5A" in the spec is
  read as the full-video deletion of 0004: the video is deleted by the parent or after 7 days).

## Verified
Unit tests: limits, clamping at both ends of the video, 2 s minimum, reset, older wider clips; a real re-cut that survives
reopening the store, keeps the filename, leaves no extra or `.partial` file; dragging changes nothing on disk; an older clip
gets its tap stored; no trim without the full video. Simulator: see testing log.
