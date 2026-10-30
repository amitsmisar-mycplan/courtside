# 0013 — Game library: opponent, score and notes on each game

**Status:** Accepted · 2026-10-30 (schema change approved by founder; "keep both" for name vs opponent)

## Context
The founder's game-library spec asks for opponent, date, our/their score and notes on each game; rows titled by opponent
("Untitled game" otherwise) with score and clip count; an editor; fast metadata that never blocks recording or importing;
and an empty state with record/import buttons. Much already existed: each video is a `Game`, clips belong to one game
(cascade delete), newest-first list, swipe-to-delete with confirmation, clips in time order, file cleanup on delete.

## Decision
- **Schema (`Game`)**: four optional fields — `opponent: String?`, `ourScore: Int?`, `theirScore: Int?`, `notes: String?`.
  All start nil → SwiftData lightweight migration, no data rewritten. Date stays `recordedAt` (already the video's creation
  date on import, the start time when recording), now editable. The source video stays `videoFilename`.
- **Name and opponent both kept** (founder's choice). Title rule: `vs <opponent>` → else the name → else "Untitled game".
  Existing names (e.g. "Game — Oct 4, 2026", "Game - Oct 4 - Amit Test 1") stay as they are and still show.
  **New games start with an empty name** (no more automatic "Game — <date>"), so they read "Untitled game" until an
  opponent is added — the spec's wording, and the row already shows the date. Recovered recordings keep their
  "Recovered — <date>" name.
- **The spec's "migrate clips into an Untitled game per source video" is a no-op**: v1 never stored a clip without a game
  (0 found in the store), and each game already owns exactly one source video.
- **Score**: shown "54–48", us first; a side not entered yet shows "?" ("54–?").
- **Fast entry, never blocking**: recording asks nothing. Import creates and saves the game first, then offers one optional
  "Opponent" field (keyboard up, "Later" to skip). Everything else from **Edit** on the game page: opponent → Next jumps to
  the score, number pads, notes, date, name. The game page offers "Add opponent and score" while they're missing.
- **Empty state** carries its own "Record a Game" and "Import a Video" buttons; the bottom Add Game bar appears once there
  are games.
- Delete confirmation reads "Delete Game" / "…and 1 Clip" / "…and N Clips".

## Verified
Unit tests: title rule, score text, details survive a store reopen (relaunch), deleting a game removes only its files
(video, clip, slow-mo, thumbnail) and records, a recorded game starts untitled. Simulator: v1 store with 4 games / 9 clips
upgraded in place with every game, mark and clip identical; edit → force-quit → relaunch keeps the details; import creates an
"Untitled game" dated from the video; swipe-delete removes its video file and leaves the rest; empty state on a fresh device.
