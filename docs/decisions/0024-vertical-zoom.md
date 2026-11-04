# 0024 — Zoom and aim for Vertical exports of landscape clips

**Status:** Accepted · 2026-11-03 (founder's "vertical zoom" spec, from reviewer feedback). Changes the Vertical layout of
[0016](0016-export-to-photos.md) for landscape clips: the parent picks how far to zoom and where to aim. Label placement
from [0019](0019-game-labels.md) is unchanged; the labelled-copy cache of [0021](0021-faster-label-export.md) gains the
zoom and aim in its key.

## Why
Reviewers found Vertical exports of landscape clips too small: a 16:9 video fit to the width of a 9:16 frame fills only
32 % of its height, the rest is blurred background.

## Decision
- **Where:** Save to Photos → Vertical, for a clip wider than tall (the clip or its slow-mo version, whichever is
  showing). The sheet grows to full height and shows a still from the middle of the clip with the 9:16 window over it;
  outside the window is dimmed. Drag to aim, slide to zoom, "Save Vertical" to render. "Back" returns to the format
  list. Portrait and square clips export straight away, exactly as before. Share always uses Original, so it is unchanged.
- **Zoom:** 0 % is the old layout (the video fits the width, blurred above and below). 100 % fills the 1080×1920 frame
  from top to bottom and crops the sides. In between, the scale moves evenly from one to the other. Default 60 %,
  centered; the zoom of the last Vertical saved is the next default (`VerticalZoomSettings.lastZoom`). Aim isn't
  remembered: each clip starts centered.
- **Aim:** left and right whenever the window is narrower than the video. Up and down needs a window shorter than the
  video, which only happens past 100 %, so within the slider's range the window is always vertically centered. The math
  supports it; the slider never reaches it.
- **Quality limit:** the slider stops where a source pixel would be stretched past 1.5× (`VerticalFraming.maxUpscale`):
  full 100 % for 4K, 77 % for a 1920×1080 clip, 36 % for 1280×720, none below that. At the limit the sheet says "Zoom
  limited by video quality". Because new clips are 1080p by default ([0023](0023-clip-quality.md)), most clips stop at
  77 %; a clip made at Full quality from 4K footage can fill the frame.
- **Pipeline:** `VerticalFraming` (pure geometry in `ExportPlan.swift`) gives where the video goes in the frame;
  `ExportPlan.verticalFraming` carries it; `ExportComposer` uses it for the layout step instead of fitting the width, and
  skips the blurred background when the video covers the whole frame. Same Core Image composition, same HEVC 1080p
  preset for labelled exports, still through `ClipExtractor`, serial, never passthrough. Output is always 1080×1920.
- **Label:** the label stays where it was: lower-left, on its dark rounded box, 22 % up from the bottom (above where
  Instagram and TikTok put the caption and account name) and ending by 76 % across (clear of their buttons). At zoom 0
  that's in the blurred area under the video, as before; once zoomed, the video covers that spot, so the label sits over
  the video on its box. Its position was already the safe area the spec asks for, so it doesn't move.
- **Cache:** a labelled copy's key includes the zoom (to 1 %) and aim (to 0.1 %). A different zoom or aim makes a new
  copy and the old one for that clip is removed.

## Export cost
Labelled Vertical save of a 13 s clip, "Courtside Tests" Simulator, real footage, one run each (seconds; see
[testing](../testing/simulator-verification.md#vertical-zoom)):

| Clip | Old layout (no zoom code) | Zoom 0 % | Zoom 60 % | Zoom 100 % |
|---|---|---|---|---|
| 4K (3840×2160, cut at Full quality) | 58.4 | 64.9 | 70.6 | 74.1 |
| 1080p (1920×1080) | 58.0 | 58.8 | 70.6 | 74.0 (held to 77 %) |

Every output is 1080×1920, 16–19 MB. Zoom 0 % and the old layout make the same picture; 58.4 against 64.9 for 4K is
run-to-run noise. Zoomed exports take about 10–25 % longer (12–16 s here). The layout work is the same Core Image
scale and crop at every zoom, and at 100 % the blur isn't drawn at all, so the likely cause is the encoder: a frame full
of real detail is more work than one that's two-thirds blur. Not confirmed; see Tradeoffs.

## Tradeoffs
- A 1080p clip (the default since 0023) can't fill the frame: 77 % leaves thin blurred bands above and below. Filling
  it would stretch each pixel 1.8×, visibly soft. Clips made at Full quality from 4K can.
- Zoom applies to the whole clip: the window doesn't follow the play. Aim picks one spot for the whole clip.
- The still is from the middle of the clip; the action may be elsewhere at the start or end.
- Zoomed exports take 10–25 % longer than the old layout on the Simulator (about 12–16 s on a 13 s clip). The spec
  asked for "about the same"; this is close but not equal, and the cause (encoder vs. composition) wasn't isolated.
