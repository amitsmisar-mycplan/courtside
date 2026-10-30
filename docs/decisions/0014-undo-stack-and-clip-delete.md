# 0014 — Repeatable Undo while marking; delete clips by swipe or selection

**Status:** Accepted · 2026-10-30 (founder's "undo mis-taps and delete clips" spec)

## Undo
- **A stack, not one step.** `MarkUndoStack` holds the identifiers of recent taps. Undo removes the newest one, again and
  again. The button reads "Undo" for one, "Undo 3" for several.
- **By identifier.** Undo finds the mark by its `id`, never by list position or by the latest time. Taps can land out of
  time order after scrubbing; the test taps 5, 10, 30, 20, 15 s and undoing three removes 15, 20 and 30. A mark already
  gone is skipped.
- **Window: 5 s from the last action.** Each tap or undo restarts it; once Undo has sat untouched for 5 s it hides and the
  stack is forgotten, so Undo never reaches back to a tap from minutes ago. (Matches the existing 5 s undo of 0006.)
- **Same for imported and recorded games.** Playback marking (`MarkingSession`) and live recording (`RecordingSession`)
  share `MarkUndoStack`; nothing looks at `Game.source`.
- **Taps unchanged.** Marking still happens on touch-down with the haptic and flash; the Undo control sits in the corner,
  outside the tap area's way, and adds no work to the tap. After an undo, the 2 s repeat guard resets so the next tap
  counts.

## Deleting clips
- The game page's clip grid became a list (a grid can't swipe or multi-select): thumbnail, clip times, length, slow-mo tag.
- **Swipe** a clip → Delete. **Select** → tick clips → Delete. One clip goes straight away; **more than one asks first**.
- Files go only through `StorageManager.deleteClips`: the clip video, its slow-mo render and its thumbnail.
- ~~The marks behind deleted clips stay.~~ Changed 2026-10-30: deleting a clip also deletes the mark it was made from
  (matched by the clip's stored tap time), so the game's mark count matches its clips. Clips made before the tap time was
  stored (pre-0007) have no reliable match and keep their mark.

## Verified
Unit tests: tap 5 / undo 3 leaves the right 2 marks for a recorded game and an imported game (out-of-order taps); the stack
window and restarts; a vanished mark is skipped; deleting 2 of 3 clips removes exactly their files. Simulator: Undo button
counts and removes marks (checked in the store); swipe delete and 2-clip select-delete with confirmation; every deleted
clip file gone, other games' clips untouched.
