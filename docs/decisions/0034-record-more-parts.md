# 0034 — Recording more parts into the same game

**Status:** Accepted · 2026-11-18 (founder's "three recording-flow problems" fix). Changes one line of
[0022](0022-multi-part-games.md): "Recording into an existing game is not built." Nothing in
[0004](0004-video-retention-and-nudge.md) changes. No schema change.

## The problem (found at a real game)
After starting and stopping a recording, the parent had to create a new game to record again.

The cause:
- `RecordingSession.stop()` ends in `.finished` and nothing moves it back. `start()` needs `.ready`, so it does nothing.
- `start()` always inserted a brand-new `Game`.
- The finished screen offered only Make Clips and Done, and Done closed the recording screen.
- The only Record button was on the games list, and it always makes a new game.
- The game page had no way to record.

The game itself was fine: Part 1 saved with its duration and marks. Nothing refused to record into it; there was simply
no path to.

The camera code (`CaptureSessionController`) was never the obstacle: it starts a new file with a new name after any stop.

## Decision
- **Next part.** A recording session can be given a game. When it has one (opened from the game, or after a stop on the
  recording screen), `start()` adds the game's next part (`nextPartIndex`), named after the new file, like Add Video
  does. Without one it creates the game with Part 1, exactly as before.
- **Recording again.** The finished screen has **Record Part N**. It goes back to Start Recording with the camera still
  running; mark count, timer and Undo start fresh for the new part.
- **From the game page.** Add Video now offers **Record Part N** above Import from Photos and Import from Files.
- **Marks and the stop fallback.** Marks belong to the part being recorded; before, they were always Part 1. The save
  after a failed stop uses that part too.
- **Legacy fields.** The game's fields from before parts (`legacy…`) are written only when Part 1 is recorded.
- **Source.** `Game.source` stays what it was at creation: a recorded part in an imported game leaves it "Imported".
  Nothing branches on it.
- **Short parts are kept.** A start-then-stop part is kept however short. The rule never to lose footage applies;
  nothing hides parts.
- **Crash during Part 2.** The existing recovery covers it: a part saved at zero length gets its real length on the next
  launch.
- **Retention.** Unchanged (0022): a new part is "not yet marked", so it's never deleted with the processed parts.

## Tradeoffs
- Every start-then-stop leaves a part, so an accidental tap leaves a tiny part on the game page. Hiding very short
  parts was left out (listed as an extra) because it would hide footage.
- Recording settings are per recording: a new part can use a different lens than the one before.
