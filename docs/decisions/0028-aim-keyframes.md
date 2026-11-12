# 0028 — Aim points: the Vertical window glides between moments

**Status:** Accepted · 2026-11-11 (founder's "aim keyframes" spec). Extends [0024](0024-vertical-zoom.md): one aim for the
whole clip becomes an ordered list of aim points. Zoom stays one value per export. Adds an optional field to `Clip`
(lightweight migration). Changes 0024's "Aim isn't remembered" — aim points are kept per clip. No computer vision: the
tracker spike on `spike/tap-to-follow` failed, so this is manual.

## Decision
- **Data.** `Clip.aimTrackData` (optional, JSON) holds an `AimTrack`: points of time, horizontal aim, and optional
  vertical aim (nil = centered; up/down needs zoom past 100 %, which 0024's slider never reaches). Times are **game-video
  seconds**, like `Clip.markSeconds`, so a trim or a new slow-mo render never moves a point off its moment. The track has
  a format `version` and an `origin` (`manual` today, `automatic` reserved): a tracker can later fill in any number of
  points and playback and export handle them the same way. Nil (all existing clips) is one centered aim, exactly as before.
  The data lives on the clip's own record, so deleting the clip deletes it; no files, no URLs.
- **Editor.** Save to Photos → Vertical on a landscape clip. The clip plays under the 9:16 window instead of a still, with
  a scrub bar and Play/Pause. A new clip has one point, which aims the whole clip (0024's behavior: drag anywhere). "Add
  Point" adds one at the playhead with the window's current aim; then drag to aim it. On a point (within 0.2 s; the window
  turns yellow), dragging moves that point's aim and "Delete Point" replaces "Add Point". Between points, a drag makes a
  dashed draft that "Add Point" keeps and scrubbing drops. Points show as diamonds on the scrub bar: tap one to jump to it,
  drag it to move it in time (it stays between its neighbors). Up to 5 points. Changes are saved to the clip as they're
  made; back to one centered point stores nothing.
- **Layout.** The editor uses `VideoFirstLayout` (0025): the video takes the height the controls leave, down to 160 pt,
  then the page scrolls. The play/time/point row stacks under large text.
- **Motion.** Before the first point the window holds its aim; after the last it holds that one. Between two points it
  glides with **true ease-in/out** (smoothstep: starts and ends at rest). Easing is not limited by the composition API
  because `ExportComposer` already places every frame itself with Core Image; the per-frame placement just reads the
  time. **Speed cap:** at most 1 window width per second at the fastest moment of a glide. When two points are too close
  in time for their distance, the window **falls short** (it goes as far as the cap allows by that point's time, and the
  next glide starts from there) rather than arriving late, so points never shift in time. Aims are clamped inside the
  video at the export's zoom, so changing the zoom after setting points can't push the window off the picture.
- **Same math for preview and export.** `AimPath.motion(zoom:videoSize:)` (pure, `Processing/AimPath.swift`) gives the
  window at any time. The editor draws it over the playing clip; `ExportComposer` places each frame with it.
- **Export pipeline.** `ExportPlan.aimPath` (Vertical only) carries the points on the exported file's timeline. A path
  that never moves (one point, or all points at the same aim) is folded into `verticalFraming`'s center and `aimPath` is
  nil, so **a one-point clip builds the same plan as before** and takes the unchanged static code path. Still one export
  path: `ClipExtractor.exportForSharing` → `ExportComposer`, same presets (HEVC Highest Quality, or HEVC 1080p for
  labelled exports at "1080p (faster)"), same 1.5× upscale cap, label drawn on top as before, serial, never passthrough.
  There's no end card yet; the timeline step is untouched.
- **Slow mo.** Points are stored in game time and converted to the file's time (`AimTimeline`), so a slow-mo version
  glides over its stretched segment at the right moments, and more slowly (the cap is in seconds of the file).
- **Trim.** `ClipExtractor.trim` re-maps the points: every point keeps its game moment. A point now outside the clip moves
  to the nearest edge; when several would land on the same edge, the one closest to it is kept. The clip still starts and
  ends aimed where it was at those moments, and a trim never adds points.
- **Cache.** A labelled copy's key includes the points (rounded to 0.01 s and 0.1 %), as 0024 did for zoom and aim.

## Export cost
Vertical at 60 % zoom, a 13 s clip cut at the default "Clip quality" (1080p), "Courtside Tests" Simulator, real footage,
one run each (seconds; see [testing](../testing/simulator-verification.md#aim-points)):

| Source (cut to 1920×1080) | Static, label | 3 points, label | Static, no label | 3 points, no label |
|---|---|---|---|---|
| Nov 1, 20261031_144828 (4K) | 81.2 | 80.9 | 75.4 | 76.2 |
| Oct 4, DJI_20261004_103320 (1080p) | 70.0 | 68.4 | 69.4 | 68.7 |

The 3 points were 0.2 → 0.8 → 0.5 across the width at 1 s, 6 s and 11 s. **Moving the aim costs nothing measurable**
(differences within ±1.6 s, both directions, run-to-run noise): the per-frame placement is the same Core Image scale and
crop as a static aim, with a different offset. Every output is 1080×1920, 17–19 MB. Simulator times; the phone's
hardware encoder is faster in absolute terms.

## Tradeoffs
- Stop-and-go: the window comes to rest at every point. With many points close together the motion is calm but
  not continuous.
- Points closer than the cap allows don't fully reach their aim. The editor shows where the window actually is (the same
  math), but doesn't explain why it fell short.
- A draft that isn't added is dropped when you scrub or save. The dashed window and the hint say so.
- The editor plays the file being exported (the clip, or its slow-mo version), not the full game video.
