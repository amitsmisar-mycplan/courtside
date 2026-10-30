# 0016 — Save a clip to Photos, as is or vertical (9:16)

**Status:** Accepted · 2026-10-30 (founder's "export to camera roll" spec)

## Decision
- **"Save to Photos"** on the clip screen (main button) opens a sheet with two choices: **Original** (the clip as it is;
  labelled with its real shape, 16:9 or 9:16) and **Vertical** (1080×1920 for Instagram Reels / TikTok). It saves the
  version showing — the slow-mo render when Slow Mo is selected. **Share** stays, now through `ShareService`.
- **Vertical layout:** the video fit to the width and centred, over a copy of itself scaled to fill the frame, blurred
  (Gaussian, radius 36 px) and darkened 8 %. No black bars. Upright clips already 9:16 fill the frame with no background.
  Built with `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`.
- **Same export path and preset.** `ClipExtractor.exportForSharing` → the existing private `run`, which now takes an
  optional video composition. **HEVC Highest Quality, unchanged — no preset change, so no preset decision needed.**
  Re-encoded, never passthrough. Serial, with progress; Cancel stops it and removes the partial file.
- **Original isn't re-encoded:** with no layout and no frame steps, the clip file itself goes to Photos (no temp file,
  no quality loss, instant).
- **Extensible:** `ExportPlan` lists the pipeline — source → timeline steps → layout → frame steps → export.
  Watermark (feature 7) is an `ExportFrameStep` drawn on each frame; end card is a timeline step (extends the asset
  before layout); slow motion (feature 9) already produces a file used as the source, and a slow-mo *step* would build its
  composition from the source the same way. No rewrite needed for either.
- **Services, not views:** `PhotoLibraryService` (add-only permission, save), `ShareService` (share sheet),
  `ClipExportSession` (permission → render → save → clean up). Views only show state and send intents.
- **Permission:** add-only (`.addOnly`), asked the first time someone saves, *before* rendering so a refusal costs no
  wait. Usage text: "Courtside saves the clips you choose to your photo library, ready to post. It never reads or changes
  your other photos." Refused → a message and an **Open Settings** button; nothing rendered.
- **Temporary files** go in `tmp/Exports` via `StorageManager`; removed after saving (or on cancel/failure), and anything
  left (crash, force-quit) is swept on launch.

## Why blur, not center-crop
Blur keeps the whole play in view (a crop of 16:9 to 9:16 keeps only 32 % of the width — often not the ball). The spec
offers center-crop with an offset slider as the fallback if blur is too slow on a device; in the Simulator (software
encode, slowest case) a 13 s 4K-sourced clip took 46 s and an 18 s 4K clip 70 s. **Device timing is still to be
measured**; switch to crop only if a real iPhone is unacceptably slow.
