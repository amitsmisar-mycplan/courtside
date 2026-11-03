# 0020 — Share carries the game label

**Status:** Accepted · 2026-11-02 (founder's "label on Share" spec). The temporary-file rule below is superseded by
[0021](0021-faster-label-export.md): labelled copies are now cached while the app runs. Extends [0019](0019-game-labels.md), whose
"Share still hands over the clip file as it is" no longer holds, and [0016](0016-export-to-photos.md).

## Decision
- **Same rule as Save to Photos.** When a label applies (setting Open and close, and the game has a team, opponent or
  tournament), Share first renders the labelled **Original** (the clip's own shape) and opens the share sheet with that
  file. No format choice.
- **Same pipeline.** `ClipShareSession` builds the plan with the same `ExportPlan(source:format:label:)` that
  `ClipExportSession` now uses, and renders through `ClipExtractor.exportForSharing`: same preset, re-encoded, serial,
  no new export path.
- **Fast path kept.** With the setting Off or no label text, the clip file itself goes straight to the share sheet,
  instantly, as before; no progress sheet appears.
- **Progress and Cancel.** While the labelled copy is made, a small sheet shows "Making video with label…", the
  percentage, "Adding label, takes longer" (the export sheet's wording) and Cancel. Cancel stops the render and leaves no
  file; the sheet can't be swiped away mid-render, and closing it cancels.
- **Temporary file.** Written to `tmp/Exports` via `StorageManager.makeExportURL`, removed as soon as the share sheet
  closes (shared or not), on cancel and on failure; anything left by a crash is swept at the next launch with the
  export leftovers.
- **Testable.** The share sheet comes through a small `FileSharing` protocol (`SystemFileSharing` wraps
  `ShareService`); tests use a fake that records what it was handed.

## Verified
- Unit tests (`ClipShareSessionTests`):
  - With a label, a rendered copy in Exports is shared; the label box is measured in it, then it's gone after the
    sheet closes, and the clip itself is untouched.
  - With the label Off, or no label text, the clip file itself is shared and nothing is rendered.
  - Cancel mid-render shares nothing and leaves no partial or finished file.
- Simulator: the 6 s clip of the "Eagles vs Lakers" test game showed the progress sheet with Cancel. The share sheet
  then opened with the labelled 12.8 MB copy (label visible at 1 s), and closing the share sheet emptied `tmp/Exports`.
