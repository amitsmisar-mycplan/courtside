# 0031 — Find Moments review: bigger video, full screen, decided moments fade out

**Status:** Accepted · 2026-11-17 (founder: "we need to make the video larger; the moments can fade away after
accepted/dismissed"; the founder chose zoom *and* full screen). Layout and review flow only: no model, scan, export or
storage change. Changes the review screen of [0029](0029-find-moments.md).

## Why
On the review screen the preview was a 16:9 box capped at 280 pt, so wide game footage was 226 pt tall on an iPhone 17
Pro with black bars around it, and decided moments stayed in the list as "Added · Undo" rows, pushing the ones still
to review down.

## Decision
- **Taller preview, zoomed.** The preview takes 45% of the screen's height under the title (30% at accessibility text
  sizes). Wide footage is zoomed to fill it, so its left and right edges are cut off in the preview; the moment's time and
  a full-screen button sit on it. Portrait footage (by its rotation tag) is not zoomed: it fits whole in the taller box.
- **Full screen.** Tapping the preview, or its button, turns the screen sideways and plays the moment as large as it
  fits; turning the phone sideways does the same. Portrait footage goes full screen upright instead. Full screen has the
  time and sound, Accept / Dismiss (or Added / Dismissed with Undo), arrows to the previous and next moment in the list
  (wrapping round), an Undo bar for the last decision, and a button back to the list. With nothing left it dims the
  picture and offers "Back to List". The screen locks to portrait again when it closes, as marking does
  ([0008](0008-marking-any-orientation.md)).
- **Decided moments fade out.** After Accept or Dismiss the row shows "Added" or "Dismissed" for about a second, then
  fades out of the list, and the next pending moment plays. An Undo bar at the bottom offers the last decision for 5
  seconds; "Show N Reviewed" under the list brings decided moments back with their Undo, as before. With nothing left the
  list says "All reviewed" and the header counts what was added.
- **Reopening** a part whose moments are all reviewed selects nothing (the preview says "All reviewed") rather than
  playing a moment the list doesn't show.
- **Largest text:** a row's Dismiss and Accept stack full width instead of breaking mid-word (they did on main).
- The review state (what's listed, leaving rows, last decision, arrows) lives in `MomentReviewSession`; the view keeps
  only timing and orientation. `LoopingClipPlayer` now reports the video's shape (rotation applied) for the
  zoom/upright choice.

## Measured
"Courtside Tests" (iPhone 17 Pro), the Nov 1 landscape video `20261031_151837`: the preview went from a 280 pt box with
a 226 pt picture to 326 pt, filled. "Courtside Tests SE": 267 pt (was a 280 pt box with a 211 pt picture for wide
footage). Full screen uses the whole width in landscape: 874 × 402 pt on the 17 Pro.

## Tradeoffs
- The zoomed preview cuts off the sides of wide footage (about 30% of the width on a 17 Pro); a play at the edge of the
  court needs full screen.
- A list holds fewer rows above the fold (the preview is taller); decided moments no longer take space, which makes up
  for some of it.
- Undo for anything but the last decision is one tap further away ("Show N Reviewed").
- Footage tagged portrait but filmed with the phone sideways (rotation lock on) plays sideways, here as everywhere else
  in the app: the file says portrait.
