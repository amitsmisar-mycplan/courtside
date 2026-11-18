# 0032 — Wide / Medium / Tight framing for Vertical exports

**Status:** Accepted · 2026-11-17 (founder's "framing presets" spec). Copy and layout of the Vertical framing step only;
the zoom scale, export math, timing, `ClipExtractor`, models and storage are unchanged. **Changes
[0024](0024-vertical-zoom.md)'s default**: a new Vertical starts at Medium instead of the zoom of the last Vertical saved.

## Why
The zoom slider showed only a percentage, and a vertical frame is a narrow slice of a landscape clip: a founder's clip at
77 % zoom with one aim point lost the players at both sides. A choice named by what it shows is easier to judge.

## Decision
- **Three choices, on 0024's scale.** `FramingPreset` picks points on `VerticalFraming`'s existing zoom scale (0 = the
  whole width, 1 = filling the frame's height, scale moving evenly between) by the share of the video's width the 9:16
  frame keeps. It inverts `VerticalFraming.scale` (scale = canvas width ÷ (share × video width)); no new math.
  - **Wide:** two thirds of the width. Zoom 0.231 on any 16:9 clip.
  - **Medium:** half the width. Zoom 0.463 on any 16:9 clip.
  - **Tight:** as close as the clip allows: `VerticalFraming.maxZoom`, the 1.5× upscale cap. 1.0 for 4K (31.6 % of the
    width); **0.771 for 1920×1080, which is the cap** (37.5 %); for 1280×720 the cap is 0.362, below Medium.
  - Choices that land on the same zoom (within 1 %) are left out: a 720p clip offers Wide and Medium (Medium held at the
    cap, 55 %), a clip too small to zoom offers Wide alone (the picker is hidden).
- **Default Medium**, every time (the closest wider choice when a clip offers no Medium). Today's 60 % default kept about
  44 % of the width; Medium keeps 50 %. The zoom of the last Vertical saved is no longer the next default, so
  `VerticalZoomSettings` (its only use) is removed. Zoom was never stored per clip, so no saved clip changes; the old
  "verticalLastZoom" value stays in the phone's settings unread.
- **Readout** under the choice: "Shows about N% of the court width.", from the actual window and source sizes, to the
  nearest 5 %. One line, so the video keeps its height.
- **Warning** when Tight is selected or the clip has one aim point, and the frame crops the sides: "Players near the
  sides may be cut off. Use Add Aim Point to follow the play."
- **Advanced:** the 0024 slider, its percentage, the blurred-background note and the quality-limit note ("This video's
  quality limits zoom to 77%.") are under a collapsed "Advanced" disclosure. Moving the slider off a choice leaves none
  selected; the export uses whatever zoom is set.
- **One static zoom per export** ([0028](0028-aim-keyframes.md)) is unchanged: the choice sets the session's zoom, which
  the export reads as before.

## Verified
"Courtside Tests" (4K landscape clip: Wide 65 %, Medium 50 %, Tight 30 %) and "Courtside Tests SE" (low-resolution clip:
Wide and Medium only, Medium 55 %): the video box is the same height as before at default and the largest text size.

## Tradeoffs
- Medium every time means a parent who always wants Tight picks it each time.
- At the largest text sizes the segmented control's labels don't grow (a system control); they stay legible.
- The warning shows by default (one aim point), which is most clips; it's the case the founder hit.
- The quality limit is no longer stated next to the choice (it would wrap and cost the video height on small phones);
  Tight simply is the limit, and Advanced still says it in numbers.
