# 0022 — Games with more than one video ("parts")

**Status:** Proposed · 2026-11-03 (founder's "multi-part games" brief). Plan only; nothing is built until the founder
says "go". Changes the retention rules of [0004](0004-video-retention-and-nudge.md) for games with more than one video.

## Data model
New `GamePart` model, owned by `Game` (cascade delete):

| `GamePart` field | Meaning |
|---|---|
| `id` | Also names the video file (`<id>.<ext>`), like a game's video today |
| `index` | 0-based order; shown as "Part 1", "Part 2" |
| `videoFilename` | Relative filename only; `StorageManager` builds the URL |
| `durationSeconds`, `videoFileSize` | Captured at import or recording stop, so views never stat files |
| `recordedAt` | The video's own creation date (or the recording start) |
| `isVideoAvailable` | False once this part's video is deleted or found missing |
| `processedAt` | When clips were last made from this part; starts this part's 7-day clock |
| `marks`, `clips` | Inverse of `Mark.part` and `Clip.part` |

- **`Mark` and `Clip` gain `part: GamePart?`.** Their times (`offsetSeconds`, `startSeconds`, `endSeconds`,
  `markSeconds`) stay as they are and mean seconds in *that part's* video. They keep `game` too, as the owner whose
  cascade delete removes them, so every game-level query (`game.clips`, the label, export, share) works unchanged.
- **Stays on `Game`:** id, name, date (`recordedAt` = when the game was played, from Part 1), source, team, opponent,
  scores, notes, tournament, `keepsVideo` (game-wide, below), `isProcessed` (all marks across parts have clips),
  `marks`, `clips`.
- **Moves to the part:** video filename, duration, file size, availability, `processedAt`. On `Game` these become
  computed: `durationSeconds` and video size are the totals, `isVideoAvailable` is "any part available",
  `orderedParts` sorts by index.
- **Old stored fields are kept, not dropped.** `videoFilename`, `durationSeconds`, `videoFileSize`,
  `isVideoAvailable` and `processedAt` stay in the store, renamed in code with `@Attribute(originalName:)` (for
  example `legacyVideoFilename`). That's a lightweight change. New games write Part 1's values into them too. They
  are only read by the migration step and by orphan recovery's list of known files. Removing them is a later
  decision, once every device has migrated.

## Migration
SwiftData's lightweight migration can add the `GamePart` table, the two optional relationships and the renames, but it
can't create rows. So there are two steps:
1. **Back up, then open.** Before the container opens with the new schema, the store files (`default.store`, `-wal`,
   `-shm`) are copied once to `Application Support/StoreBackup-0022/`, if that folder doesn't exist yet. If opening
   ever fails, the original data is still there, and so are the videos, which are never touched by migration.
2. **Backfill at launch, before cleanup and recovery.** Every `Game` with no parts gets "Part 1", built from its
   legacy fields. All its marks and clips point to it, and the result is saved once. The step can be run again
   safely: games that already have parts are skipped, and a failed save leaves the legacy fields to try again next
   launch. No file is moved, renamed or deleted, and times need no change, because Part 1 is the old whole video.

Defensive fallback: code that needs a mark's or clip's part uses `part ?? game.orderedParts.first`, so a record seen
before the backfill still plays the right video.

## How each flow changes
- **Import (new game):** unchanged copy, progress, cancel and 2× free-space check. The game is created with Part 1.
  `VideoImporter` only renames `gameID` to `videoID` (the file's UUID).
- **Add Video (new):** same `ImportFlowView` and `VideoImporter` path with a target game. On success it inserts a
  `GamePart` with the next index and saves, and the opponent step is skipped. If the app dies between the file move
  and the save, the file is an orphan and recovery makes it its own "Recovered" game, so the footage is kept.
- **Recording:** `RecordingSession` creates the game with Part 1 (duration 0 until stop), and live marks get Part 1.
  Recording into an existing game is not built.
- **Orphan recovery:** known files = every part's filename ∪ every game's legacy filename. Any other complete file in
  `Games/` is still an orphan and becomes a new one-part game, as today. Zero-length recovery runs per part.
- **Marking:** `MarkingSession` and `PlaybackMarkingView` take a part. They play that part's video, take its duration,
  and set `part` on new marks. Ticks, mark count, Undo and the 2-second guard are per session, so they're per part.
- **Game page:** with one part it looks as today. With more, a "Parts" section lists "Part 1 · 23:10", "Part 2 ·
  18:45", and tapping one opens marking for it. "Add Video" sits under the actions. "Make N Clips" covers pending
  marks in every part whose video is available.
- **Clip making:** `ClipExtractor.start(game:)` takes the pending marks in part order, then time. Each clip is cut from
  its mark's part, with the window clamped to that part's duration, so a clip never crosses a boundary. The
  already-made check (clip ID = mark ID, else same tap time) only compares clips in the *same part*. `Clip.part` is
  set, and `processedAt` is set on the part. Clip names stay `<markID>.mov`, unique across parts.
- **Background resume:** unchanged mechanism (game IDs in `UnfinishedClips`). "Waiting" means pending marks on parts
  whose video is available. A resumed run covers all parts, with one clip per mark and no duplicates.
- **Trim:** `TrimSession` and `ClipExtractor.trim` use the clip's part: its video, and its duration as the bound.
- **Export, share, label, labelled-copy cache:** no change. They work from the clip file and game fields, and the cache
  key already includes the clip ID and source file.
- **Clip list:** sorted by part index, then start time. The row shows "Part 2 · 3:10 – 3:23" only when the game has
  more than one part.
- **Storage:** game size = available parts' videos + clips. The Games list shows one row per game, with the total
  duration and size.
- **Deleting a game:** removes every part's video, every clip's files, thumbnails and cached labelled copies, then the
  records.
- **Deleting a clip:** still deletes its mark. Matching by tap time (for old clips) is scoped to the clip's part.

## Rules where the brief is silent (proposed)
1. **Keep is game-wide.** "Keep" in the prompt sets `Game.keepsVideo`, and it covers parts added later too. Keep means
   "keep this game's footage", and the safer reading wins.
2. **Expiry is per part.** A part's video auto-deletes 7 days after *its own* `processedAt`, unless the game is kept.
   A part that was never processed never expires (same as a game today).
3. **The prompt's "Delete" removes only processed parts:** available parts whose marks all have clips and that have a
   `processedAt`. A part added but not yet marked is never deleted by it. The prompt shows that size and says "the
   videos of the parts you've made clips from" when the game has more than one part.
4. **Adding a part to a processed, deleted or expired game is allowed.** The new part is available and can be marked.
   Older parts stay unavailable, and their clips are kept. The prompt appears again after its clips are made, unless
   the game is kept.
5. **"Delete…" on a kept game** (game page) removes all parts' videos after the confirmation, which lists the total.
   Deleting one part's video is not built.
6. **A clip never crosses a part boundary;** windows and trim bounds are clamped to the part (founder's answer).
7. **Mark More Plays with one part** opens that part directly. With several, the parent picks a part in the list.

## Riskiest points for losing footage
| Risk | How the design avoids it |
|---|---|
| Migration fails or corrupts the store | Additive and rename-only schema change; one-time store backup before opening; the backfill writes no files, runs again safely, and the legacy fields stay. Tested on an old-format store. |
| Part 2+ files look like orphans | The known-files list includes every part. Tested: a two-part game survives recovery with no new game. Even if this failed, recovery only creates games and never deletes. |
| Retention deletes footage the parent hasn't marked | Expiry and the prompt's Delete only touch processed parts. Tested per part. |
| Missing-file check marks the wrong part unavailable | Checked per part by its own filename; nothing is deleted by it. |
| Deleting a game removes another game's files | Deletion goes through `StorageManager` by each part's own filename only. A test checks no stray and no extra files. |
| Add Video interrupted mid-import | The existing partial-file and orphan rules apply: a `.partial` is swept, and a complete file with no record becomes a recovered game. |

## Conflicts with CLAUDE.md
None. No logic branches on `Game.source` (the only use stays the display-only Photos note). Picked videos are still
copied, only relative filenames are stored, `StorageManager` builds URLs, and `ClipExtractor` runs every export. One
point to be clear about: the schema change itself is a lightweight migration, but filling in Part 1 is a data step in
code, because lightweight migration can't create rows. This record and the backup cover it. Retention rules 2, 3 and 5
change how source videos are deleted, which is what CLAUDE.md asks a decision record for.

## Estimate
About 20 app files (4 models + the new one, `StorageManager`, app startup, importer, import flow, marking session and
view, trim session, extractor, resume, recording session, game page, processing view, clip player), about 14 test
files updated (mostly `Game(...)` call sites) plus 3 new (migration, multi-part model and deletion, and a stress-harness
scenario), and 4 docs. **About 40 files.**

## Not built (extras)
Reordering parts, deleting a single part or its video, recording into an existing game, merging games, moving a part
to another game, a per-part Keep.
