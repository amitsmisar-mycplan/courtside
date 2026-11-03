# Progress

_Last updated: 2026-11-03_

| Step | What | Status |
|---|---|---|
| 1 | Models, `StorageManager`, clip-window math + tests | ✅ Done |
| 2 | Games list, import flow, empty states | ✅ Done |
| 3 | Playback marking | ✅ Done |
| 4 | Clip extraction + processing screen | ✅ Done |
| 5 | Clip player, nudge, share, delete | ✅ Done |
| 6 | `RecordingService` + `CaptureSessionController` | 🧪 Built and unit-tested; needs the device test |
| 7 | Resilience (thermal, interruption, disk) | 🧪 Footage-safety parts built with step 6 ([0011](../decisions/0011-recording.md)); needs the device test |
| 8 | Acceptance test | ⏳ After step 7 |

**Since steps 1–5:** "Keep the full game video" now means keep forever (decision 0004).

**Feature: slow motion** ([spec](../feature-slow-motion.md), [decision 0007](../decisions/0007-slow-motion.md)) — built on `feature/slow-motion`; Simulator verification in [testing](../testing/simulator-verification.md#slow-motion).

**Slow-mo preview** now plays full screen, looping, turned to match the video, with a poster in the sheet ([0012](../decisions/0012-slowmo-fullscreen-preview.md)) — built on `feature/slowmo-fullscreen-preview`, Simulator-verified.

**Feature: game library** — opponent, score and notes on each game, edit screen, rows titled "vs Opponent", empty-state
buttons ([0013](../decisions/0013-game-library.md)). Built on `feature/game-library`; existing data migrates in place.

**Feature: undo mis-taps and delete clips** — repeatable Undo by mark ID in both marking screens; clip list with swipe and
multi-select delete ([0014](../decisions/0014-undo-stack-and-clip-delete.md)). Built on `feature/undo-and-clip-delete`.

**Feature: trim a clip** — trim screen with handles over the surrounding game video, 30 s before / 15 s after the tap,
2 s minimum, reset to 10/3, re-cut through `ClipExtractor`; replaces nudge ([0015](../decisions/0015-clip-trim.md)).
Built on `feature/clip-trim`.

**Fix:** deleting a clip (swipe, multi-select, or the clip screen) now also deletes the mark it came from, so a game's mark
count matches its clips ([0014](../decisions/0014-undo-stack-and-clip-delete.md)). Older clips without a stored tap time
keep their mark.

**Feature: save to Photos** — Original or Vertical (1080×1920, video over a blurred copy of itself), add-only Photos
permission with a Settings link when refused, cancel, temp files cleaned up ([0016](../decisions/0016-export-to-photos.md)).
Built on `feature/export-vertical`. Device timing still to measure.

**Test: real-footage stress run** — `CorpusStressTests` (skipped unless `COURTSIDE_CORPUS_DIR` is set) imported,
marked, extracted, trimmed, exported vertical and deleted across the 5 Nov 1 videos (51 min, 15.9 GB): 40 of 40 clips,
0 failures, no orphans ([results](../testing/corpus-nov-1.md#stress-test)). Three bugs found, none touching footage.

**Fix: background clip-making** — clip-making stops cleanly when iOS ends background time (current partial deleted,
everything else untouched) and finishes the missing clips by itself on return or next launch, under "Finishing your
clips"; never remakes or duplicates a clip ([0017](../decisions/0017-background-clip-resume.md)). Simulator-verified with
a force-quit; device check in [device-acceptance](../testing/device-acceptance.md#background-clip-making).

**Fix: slow-mo frame rate** — measured from the median gap between frames, so the start-up pause in phone recordings and
very short clips no longer switch off 0.5× on 30 fps footage ([0018](../decisions/0018-frame-rate-from-frame-gaps.md),
closes open question 4).

**Feature: game labels** — team and tournament on each game ("My team" setting prefills new games; tournament suggests
names already used), rows titled "Team vs Opponent" with "Tournament · date" under it, and a label burned into saved clips
for 2.5 s at the open and close (open only under 7 s), in both Original and Vertical. Setting: Off / Open and close.
Original keeps its instant save when there's no label ([0019](../decisions/0019-game-labels.md)). Built on
`feature/game-labels`.

**Feature: label on Share** — Share now sends the labelled Original when a label applies (rendered first, with
progress and Cancel, temp file removed when the sheet closes); without a label it shares the clip instantly as before
([0020](../decisions/0020-label-on-share.md)). Built on `feature/label-on-share`.

**Test Simulator** — automated builds and tests now run on a dedicated "Courtside Tests" Simulator (iPhone 17 Pro,
iOS 27), never "iPhone 17", which is kept for manual testing. Command updated in CLAUDE.md, README and docs/testing.

**Faster label export** — labelled Save to Photos, Vertical and Share are capped at 1080p by default (HEVC 1080p preset):
a 13 s 4K clip takes 65 s instead of 178 s on the Simulator. "Labelled clip quality" in Settings keeps Full quality as
an option. Labelled copies are cached while the app runs, so the same clip again is instant. Elapsed time in the
progress sheets ([0021](../decisions/0021-faster-label-export.md)). Built on `feature/faster-label-export`.
UI not yet checked in the Simulator.

**Feature: games with more than one video (parts)** — a game holds its videos in order ("Part 1", "Part 2"); "Add Video"
on the game page imports another through the same import path. Marking, clips, trim and retention work per part, and
a clip never crosses into another part. Existing games migrate to one part with everything intact (store backed up
first). Also fixes a crash when background time ran out just as a clip's export started
([0022](../decisions/0022-multi-part-games.md)). Built on `feature/multi-part-games`; Simulator-verified on "Courtside
Tests" and run on two real November 1 videos as one game.

**Next action:** install on the iPhone, verify import/marking/clips/slow mo, then run a short recording test (docs/testing/device-acceptance.md → First install), then the 90-minute acceptance test.

Remaining Simulator work before calling 1–5 fully verified: see [../testing/simulator-verification.md](../testing/simulator-verification.md#not-yet-verified).
