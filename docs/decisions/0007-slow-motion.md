# 0007 — Slow motion: schema, frame-rate cutoffs, lifecycle

**Status:** Accepted · 2026-09-30 (schema change approved by founder, option A)

Implements [`docs/feature-slow-motion.md`](../feature-slow-motion.md). Where it differs or adds detail:

## Schema (`Clip`)
Spec fields `slowMoFilename`, `slowMoSpeed`, `slowMoStartSeconds`, `slowMoEndSeconds`, plus two extras:

- **`slowMoFileSize: Int64?`** — storage totals include slow-mo files without views reading the file system (same pattern as 0001).
- **`markSeconds: Double?`** — the tap in game-video seconds. The spec's "mark sits at 10 s" is wrong for clips clamped at the
  game start, clips whose start was nudged, and clips made after the pre-roll setting changed. `markInClip = markSeconds − startSeconds`
  survives nudges.

All optional → SwiftData automatic lightweight migration; verified on a store with 20 existing clips.
**No backfill (option A):** clips made before this change use `duration − 3 s` (default post-roll) as the mark, exact for
unedited default clips. Only test data predates it.

## Frame-rate cutoffs
Read from the clip's **video track** `nominalFrameRate`.
`0.25×` needs ≥ 55 fps, `0.5×` needs ≥ 28 fps — slightly under 60/30 because phones report 59.94/29.97 and lower with variable
frame rate. 24/25 fps → no slow motion; 50 fps → 0.5× only. Clip export preserves 60 fps (tested).

## Audio
Shipped the spec's preferred approach — normal / silent gap / normal via `insertEmptyTimeRange`. No mute-everything fallback.
Tested: tone before, silence through the stretched segment, tone after; segments touching either clip edge export fine.
**When the whole clip is slowed** there is no normal-speed audio left; an audio track made only of an empty segment fails
to export, so the render has no audio track (audibly the same). Edge pieces under 1/30 s are treated as rounding leftovers.

## Lifecycle
- Render writes the new file first, then removes the previous one (different speed ⇒ different filename) — a failed render keeps the old version.
- Deleting a clip removes its slow-mo file; "Delete Slow Mo Version Only" removes just the render.
- **Nudging a clip's start/end removes its slow-mo render**, which was cut from the old clip; the player says so before you nudge.
- Abandoned `*.partial.*` renders are swept on launch like every other export.

## UI
Clip player: "Slow Mo" button → sheet (speed buttons with unavailable ones disabled and explained, draggable segment with edge
handles and a draggable middle, the tap marked in yellow, instant composition preview, size/duration estimate, Save).
After saving, an Original / Slow Mo toggle; share and the details line follow the selected version.
