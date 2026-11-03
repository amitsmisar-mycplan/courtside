# 0021 — Labelled exports at 1080p, cached while the app runs

**Status:** Accepted · 2026-11-02 (founder's "faster label export" spec). Deviates from the CLAUDE.md rule "Clip export:
`AVAssetExportPresetHEVCHighestQuality`" for labelled exports only. Extends [0019](0019-game-labels.md) and
[0020](0020-label-on-share.md); [0020](0020-label-on-share.md)'s "removed as soon as the share sheet closes" no longer
holds for labelled copies.

## Why
A label is drawn into every frame, so a labelled export can't copy the clip's frames: each one is decoded, drawn and
re-encoded at the clip's own size. Phone footage is 4K. Measured on the Simulator with real footage (13 s clips, see
[testing](../testing/simulator-verification.md#faster-label-export)):

| 13 s clip | No label (frames copied) | Every frame re-made, nothing drawn | Labelled, before |
|---|---|---|---|
| 4K (3840×2160) | 0.1 s | 184.6 s | Save 177.7 s · Share 179.1 s |
| 1080p (1920×1080) | 0.1 s | 68.5 s | Save 67.7 s · Share 66.0 s |

Drawing the label costs nothing measurable; the time is the full decode + encode at 4K that any drawing forces.
Encoding a quarter of the pixels is ~2.7× faster.

## Decision
- **Labelled exports are capped at 1080p** ("1080p (faster)", the default): the composition's canvas is the clip
  scaled to 1920 on the long side (never up, even pixels; portrait 1080×1920), and `ClipExtractor` exports it with
  `AVAssetExportPresetHEVC1920x1080`. This covers Save to Photos Original, Vertical (already 1080×1920) and Share when a
  label is drawn.
- **Nothing else changes.** Clips themselves, slow-mo renders and trims are untouched (still HEVC Highest Quality).
  Without a label, Original and Share keep the instant fast path (the clip file itself) and unlabelled Vertical keeps
  HEVC Highest Quality.
- **Setting "Labelled clip quality"** in Settings → Game labels: "1080p (faster)" (default) or "Full quality", which is
  exactly the behavior before this decision. Greyed out while the label is Off.
- **Same pipeline.** `ExportPlan.maxLongSide` carries the cap; `ExportComposer` sizes the canvas from it; the preset is
  chosen inside `ClipExtractor.exportForSharing`. Still one export path, serial, never passthrough.
- **Cache while the app runs.** `LabelledExportCache` keeps up to 4 labelled copies in `tmp/Exports`. Saving or sharing
  the same clip again with the same source file, format, label text and quality reuses the copy instantly, with no
  progress sheet. A change to any of them (team, opponent, tournament or date edited; quality changed; clip trimmed or
  slow mo redone) makes the old copy stale: it's removed the next time that clip is saved or shared. Copies are removed
  when their clip or game is deleted (`StorageManager.removeExports(forClipID:)` from the clip-file cleanup), when the
  oldest falls out of the 4, and at the next launch (existing export sweep). Unlabelled Vertical exports are still
  removed right after saving.
- **Elapsed time** shows under the progress bar in both sheets ("Elapsed 0:42"), counted from the start of the render.
  No estimate of the time left: progress isn't checked to be linear enough to promise one.

## After
| 13 s clip | Labelled Save, 1080p | Labelled Share, 1080p | Labelled Save, Full quality | Same clip again (cached) |
|---|---|---|---|---|
| 4K | 64.8 s (was 177.7) | 64.7 s (was 179.1) | 175.2 s | 0.0 s |
| 1080p | 66.4 s (was 67.7) | 66.3 s (was 66.0) | 66.1 s | 0.0 s |

Simulator times; the phone's hardware encoder will be faster in absolute terms. 1080p footage gets no faster from the
cap (it's already 1080p), only from the cache.

## Tradeoffs
- A labelled 4K clip is posted at 1080p. Instagram and TikTok re-compress to 1080p or less anyway; "Full quality" keeps
  the 4K option.
- Up to 4 cached copies in temporary storage while the app runs (~20 MB each at 1080p, ~26 MB at 4K for a 13 s clip).
