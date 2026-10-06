# 0009 — Slow-mo render falls back to H.264 if HEVC fails

**Status:** Accepted · 2026-10-06

## Context
The spec says to export with `AVAssetExportPresetHEVCHighestQuality`. With real phone and DJI footage, slow-mo renders failed
in the Simulator with `AVFoundationErrorDomain -11800 / -16364` ("The clip couldn't be exported").

Isolated on the failing clip, in the Simulator:

| Variant | Result |
|---|---|
| As built (scaled + HEVC) | ❌ |
| Audio clamped / no audio track | ❌ |
| No rotation flag | ❌ |
| No time scaling (plain HEVC re-encode) | ✅ |
| Scaled + H.264 preset | ✅ |
| Same composition, HEVC, on macOS | ✅ |

So it is the HEVC encoder rejecting time-scaled compositions of camera-originated HEVC clips — not our audio, rotation or
segment logic. Synthetic H.264-sourced clips didn't trigger it, which is why the earlier tests passed.

## Decision
Slow-mo export tries HEVC first; if that export fails (not cancelled), it retries once with `AVAssetExportPresetHighestQuality`
(H.264) and logs it. Regular clip export and nudging are unchanged (HEVC only — they never hit this).

## Consequences
H.264 slow-mo files are larger (4K 16.5 s: 47 MB). Whether real iPhones need the fallback is unknown — check on the first
device via the log line "HEVC slow-mo export failed, retrying with H.264".
