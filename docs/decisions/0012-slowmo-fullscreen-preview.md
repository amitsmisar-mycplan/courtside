# 0012 — Slow-mo preview plays full screen, turned to match the video

**Status:** Accepted · 2026-10-30 (founder's request; auto-rotation chosen by the founder)

## Context
The Slow Mo sheet previewed the composition in a small inline player pinned to 16:9. A portrait clip became a
thin strip; nobody could judge the slow part from it before saving. [`feature-slow-motion.md`](../feature-slow-motion.md)
says Preview plays the composition without exporting but not where; [0007](0007-slow-motion.md) recorded it as inline.

## Decision
- **Preview is full screen**, edge to edge, presented with `fullScreenCover` from the Slow Mo sheet. A cover is the only
  presentation that reaches the whole display from inside a sheet (a sheet is inset and can't rotate on its own), and it
  is how the marking screen is already shown.
- **It turns the screen to match the video**: portrait clips lock portrait, landscape clips lock landscape, using the
  existing `OrientationLock` / `.lockedOrientation(_:)`. Back to portrait on close. Shape comes from the clip's video
  track with its rotation applied (`SlowMoComposer.displaySize`), so rotation-tagged footage (DJI stored 1080×1920,
  shown 1920×1080) counts as landscape. Square counts as landscape.
- **Loops** from 1.5 s before the slow part (from 0 when the slow part starts near the clip start). Tap anywhere to
  pause/resume; a close button; nothing else.
- **The sheet shows a still poster** — the frame at the tap, at the clip's real shape, height capped at 340 pt so portrait
  posters don't push the controls off screen — with a Preview button on it. The bottom Preview button stays.
- **One player, one composition.** `SlowMoSession` still owns the only `AVPlayer`. The full-screen view renders that
  player; it builds no item of its own. Closing pauses and keeps the item, so reopening with the same settings is instant;
  any speed or segment change drops it; `tearDown()` releases it when the sheet goes away.
- The sheet's teardown is skipped while the full-screen preview is up, so covering the sheet can never release the
  player that's playing. Preview stays unavailable while rendering.

## Deliberate departure from 0008
[0008](0008-marking-any-orientation.md) lets the marking screen follow the phone: the parent turns it to suit the
video. The preview does the opposite and turns the screen for them. Different jobs:

- **Marking is a long session** — a whole game. The parent props the phone up or holds it however is comfortable and
  shouldn't have the screen spin under them; following the phone's own orientation is right there.
- **Preview is a short glance** — a few seconds, several times while adjusting. Making the parent rotate the phone
  every time just to see the clip properly is friction for no gain, and the video's orientation is known.

0008's "the rest of the app stays portrait" now has two exceptions: playback marking (follows the phone) and slow-mo
preview (follows the video).

## Verified (Simulator, 2026-10-30)
Portrait phone 4K clip and 6.4 s portrait DJI clip fill a portrait screen; 4K landscape and rotation-tagged DJI clips
turn the screen to landscape and fit without cropping; back to portrait on close with speed and segment intact; 6.4 s
clip loops; memory flat across 15 opens (details in [simulator-verification](../testing/simulator-verification.md)).
**Not verified:** whether iOS reports a disappear on the sheet when the cover presents (the guard makes it harmless either
way); how a real phone held the other way feels when the screen turns — check on the device.
