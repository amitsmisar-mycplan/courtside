# 0025 — Bigger video on the Clip and Trim screens

**Status:** Accepted · 2026-11-05 (founder's "bigger video" spec). Layout only: the player wrappers, export, trim math and
storage are unchanged. Narrows the Reset label of [0015](0015-clip-trim.md).

## Decision
- **Video first.** Both screens use one layout (`VideoFirstLayout`): the controls keep their natural size and the video
  box takes the rest of the height between the navigation bar and the bottom safe area, full width, aspect-fit inside a
  black rounded box. On a short screen or at large text the video shrinks first, to 180 pt (Clip) or 160 pt (Trim);
  only past that does the page scroll.
- **Clip screen controls, two rows.** The spec's example (Trim + Slow Mo, then Save, then Share + Delete) is three rows
  of 50 pt buttons and leaves the video 69 % of the height on an iPhone 17 Pro. To reach about 80 %, Save to Photos
  shares its row with Share and Delete, which become narrow tiles with the icon above a small label. Colors, icons and
  label text are unchanged; Save stays the wide orange button. When that row doesn't fit (a longer label such as "Save Slow
  Mo to Photos" on a narrow phone, or large text) it falls back to the spec's layout: Save on its own row, Share and Delete under it; at the
  largest text sizes every button gets its own row. Trim and Slow Mo stack the same way.
- **Info line directly under the video.** The Original / Slow Mo picker moved below it.
- **Trim screen.** Filmstrip, handles and their wide invisible grab area unchanged. Spacing tightened; "Reset to Default"
  sits on the time row when it fits and drops below the offsets when it doesn't. Its label is shortened from "Reset to
  Default (10 s before, 3 s after)" to the spec's "Reset to Default": the line just above it already shows the seconds
  before and after the tap, and VoiceOver reads the defaults as a hint.

## Result
Video box as a share of the height between the navigation bar and the bottom safe area (Simulator, default text size):

| Screen | iPhone 17 Pro (402×874) | iPhone SE 3rd gen (375×667) |
|---|---|---|
| Clip | 562 / 724 pt = 78 % | 430 / 593 pt = 72 % |
| Trim | 553 / 708 pt = 78 % | 422 / 577 pt = 73 % |

Before: a 16:9 box on Clip (about 208 pt, 29 %) and a box capped at 320 pt on Trim. Same for portrait and landscape clips:
the box size depends only on the screen; the video fits inside it.

## Tradeoffs
- About 80 %, not exactly: 78 % on a large phone, 72–73 % on a small one, where the controls take a bigger share.
- A clip with a slow-mo version shows the Original / Slow Mo picker, about 40 pt more, so its video is roughly 5 points
  of height smaller (not measured).
- A landscape clip on a portrait phone fills the width only; the rest of the taller box is black. The picture itself is
  no larger than before; portrait clips gain the most.
- Share and Delete are smaller tiles (still at least 44 pt tall and 52 pt wide) with caption-size labels.
