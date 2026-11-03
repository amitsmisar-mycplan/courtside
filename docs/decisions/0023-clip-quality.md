# 0023 — Clips and trims at 1080p by default ("Clip quality")

**Status:** Accepted · 2026-11-03 (founder's "clip quality" spec). Deviates from the CLAUDE.md rule "Clip export:
`AVAssetExportPresetHEVCHighestQuality`" for clips and trims made at the default setting. Extends
[0021](0021-faster-label-export.md), which did the same for labelled exports only.

## Why
A clip must start and end on the tap, so it can't copy the game video's frames (passthrough cuts on keyframes, a second
or two off). Every frame of the clip is decoded and re-encoded at the game video's size, and phone footage is 4K.
Measured on the "Courtside Tests" Simulator with real footage (one tap in the middle of the video, the 13 s default clip
made through `ClipExtractor`, then trimmed out by 2 s on each side; see
[testing](../testing/simulator-verification.md#clip-quality)):

| Before (today's code) | Make 13 s clip | Trim to 17 s |
|---|---|---|
| 4K (3840×2160) | 307.9 s | 327.7 s |
| 1080p (1920×1080) | 131.3 s | 128.4 s |

These were taken while the Mac was busier than for the run below: the same old behavior ("Full quality") measured
187.8 s and 234.5 s for 4K there. Compare within the After table.

As with labelled exports, encoding a quarter of the pixels is what saves the time.

## Decision
- **Setting "Clip quality"** in Settings, its own section under Clip length: "1080p (faster)" (the default) or "Full
  quality", which is exactly the behavior before this decision. It applies to clips made from now on and to trims.
  Clips already made are never changed or remade: a clip's file is only rewritten when the parent trims it.
- **1080p caps the long side at 1920.** A game video over 1920 on its long side is exported with
  `AVAssetExportPresetHEVC1920x1080` (the preset [0021](0021-faster-label-export.md) uses for labelled exports). The
  preset keeps the video's shape and rotation: 4K landscape gives 1920×1080, a portrait phone video (stored rotated or
  stored upright) gives 1080×1920. A video 1920 or smaller on its long side keeps HEVC Highest Quality at its own size,
  so it's never scaled up.
- **Still one export path.** `ClipExtractor.export` takes the quality; the batch reads the setting once per run (one run
  never mixes sizes) and `ClipExtractor.trim` reads it per trim. Serial, never passthrough, frame-accurate `timeRange`
  as before. No video composition is added for clips: the preset alone scales.
- **Nothing else changes.** Slow-mo renders, labelled exports (still under "Labelled clip quality", 0021), Vertical and
  export to Photos behave as before. A labelled export of a clip that is already 1080p isn't scaled again: 0021's canvas
  is the clip's own size when it fits in 1920, and the clip's frames go through the composition at that size.
- **Thumbnails** are still made from the clip file, so a 1080p clip has a 1080p thumbnail source. No visible change.

## After
One run, both settings back to back, same footage and same steps:

| After | Make 13 s clip | Trim to 17 s | Clip file |
|---|---|---|---|
| 4K, 1080p (faster) | **67.8 s** | **101.4 s** | 1920×1080, 19.3 MB |
| 4K, Full quality (the old behavior) | 187.8 s | 234.5 s | 3840×2160, 25.9 MB |
| 1080p, 1080p (faster) | 80.9 s | 104.5 s | 1920×1080, 19.3 MB |
| 1080p, Full quality | 78.0 s | 101.9 s | 1920×1080, 19.3 MB |

From 4K: clips 2.8× faster, trims 2.3× faster. 1080p footage is unchanged (it isn't scaled; the differences are
run-to-run noise). Trims make a longer clip (17 s against 13 s).

Simulator times; the phone's hardware encoder is faster in absolute terms, but the ratio should hold.

## Tradeoffs
- A clip from 4K footage is 1080p. Instagram, TikTok and messaging apps show 1080p or less anyway, and the full game
  video is kept for 7 days (or forever with Keep), so a clip can be re-cut at Full quality by switching the setting and
  trimming it.
- A 4K clip trimmed at 1080p becomes 1080p. Trim is the only thing that rewrites an existing clip, and it follows the
  setting at the time of the trim, as asked.
- Clips from games with several parts can differ in size if the setting changed between runs. Each plays at its own
  size; nothing downstream assumes one size.
