# Find Moments: nothing in the last 6 minutes of a 68.9-minute game

**2026-11-24 · investigation only, no behavior change.** Decisions [0029](../decisions/0029-find-moments.md) and
[0031](../decisions/0031-moments-review-layout.md).

**The game.** The founder's "Finale" game: one part of 4,131 s, on the founder's "iPhone 17" Simulator. The video was
only read. No audio, frames or video are in the repo.

**The harness.** `CourtsideTests/FindMomentsTailDiagnostics.swift` is skipped by default and set with
`TEST_RUNNER_COURTSIDE_MOMENTS_DIAG`. It listens with `MomentListener` and replays `MomentPicker`'s steps, logging why
each peak is dropped. It asserts that its choice equals `MomentPicker.pick`.

## Answer: the strongest-first cap, not the threshold, the marks, or an incomplete scan
| Check | Result |
|---|---|
| Scan complete? | Yes. `isComplete = true`, 4,132 s heard; the app's saved scan was removed, which only happens on completion. |
| Threshold | 1.50, the floor (`minimumScore`). Typical score 0.274, spread 0.406: 0.274 + 3 × 0.406 = 1.49 < 1.5. |
| Cap | 23 = ceil(4131 / 3600 × 20) |
| Peaks above threshold, whole game | 178 |
| The harness's 23 picks | Exactly the app's 23 suggestions (71 s … 3,252 s) |
| **Last 6 min (from 3,772 s)** | **124 s above threshold, 18 peaks, best score 9.69** |
| Last 6 min peaks dropped | **18 by the cap**, 0 by spacing, 0 by marks |
| Weakest score that made the cap | 9.74. The tail's best missed by 0.05. |

The raw loudness check (only 3 s at ≥ 6 dB over the floor in the tail) is right, but loudness is only 20 % of the
score. The classifier's crowd reaction is 80 %, and the tail has plenty of it:

| Stretch | Seconds with reaction ≥ 0.99 | Mean reaction |
|---|---|---|
| 0–20 min | 93 | 0.196 |
| 20–40 min | 79 | 0.202 |
| 40–62.9 min | 96 | 0.230 |
| **Last 6 min** | **43** (the highest rate) | **0.283** |

**Why the tail ranks just below the top 23.**
- **Every strong cheer hits the ceiling.** Reaction is capped at 1, so its score is about 10 and the top is a near-tie:
  the 23 chosen run 9.74–10.49.
- **The local floor decides the tie.** A second's lift is measured above the rolling 90 s median. Late in the game the
  crowd is noisier, so the floor is higher and the same full-strength cheer lifts less:

  | Peaks | Reaction floor | Reaction lift | Loudness lift |
  |---|---|---|---|
  | The 23 chosen | 0.065 | 12.0 | 1.8 |
  | The tail's maxed-out seconds | 0.135 | 11.1 | 1.0 |

- **The result:** the strongest-first cap spends all 23 slots on the first 54 minutes (the last at 3,252 s) and none on
  minutes 55–68. Minutes 55–68 have 39 peaks above threshold scoring up to 9.69.

Per minute, the end of the game (as scanned, with no marks avoided):

| Minute | Seconds ≥ threshold | Best score | Peaks | Chosen | Dropped by cap |
|---|---|---|---|---|---|
| 54 | 13 | 10.01 | 2 | 1 | 1 |
| 55 | 16 | 7.22 | 3 | 0 | 3 |
| 56 | 13 | 9.56 | 2 | 0 | 2 |
| 57 | 11 | 9.12 | 2 | 0 | 2 |
| 58 | 27 | 9.49 | 4 | 0 | 4 |
| 59 | 17 | 9.66 | 2 | 0 | 2 |
| 60 | 31 | 8.92 | 5 | 0 | 5 |
| 61 | 23 | 9.38 | 4 | 0 | 4 |
| 62 | 17 | 9.34 | 2 | 0 | 2 |
| 63 | 15 | 9.63 | 1 | 0 | 1 |
| 64 | 19 | 9.69 | 3 | 0 | 3 |
| 65 | 29 | 9.21 | 5 | 0 | 5 |
| 66 | 26 | 9.26 | 3 | 0 | 3 |
| 67 | 11 | 5.14 | 2 | 0 | 2 |
| 68 | 24 | 9.24 | 4 | 0 | 4 |

The full per-minute table for all 69 minutes comes from the harness.

**A re-scan today would put 2 in the tail.** It avoids the 16 marks, so 16 of the top spots are taken; the picks shift
to the next best, and 2 land in the last 6 minutes (3,805 s and 3,858 s).

## Options (proposed, not built), compared on this video as scanned
"On found" counts how many land within 20 s of the 23 moments the founder already reviewed.

| Option | Total | Last 6 min | On found |
|---|---|---|---|
| Today (strongest first, cap 23) | 23 | 0 | 23 |
| **(a) Each 10-minute slice first keeps its best peak, then strongest first to 23** | 23 | **1** | 21 |
| (a) The same with 5-minute slices | 23 | 2 | 18 |
| (b) Threshold measured per 10-minute section, cap unchanged | 23 | 0 | 23 |
| (b) + (a) Per-section threshold and best per 10 min | 23 | 1 | 21 |
| (c) `spreads` 2.5 / 2.0 / 1.5, cap unchanged | 23 | 0 | 23 |

The (b) section thresholds came out at 1.50 1.67 1.50 1.50 1.54 1.77 2.19.

- **(b) and (c) can't help here.**
  - **(c):** the threshold already sits at its 1.5 floor, so a lower `spreads` changes nothing.
  - **(b):** a per-section threshold only raises the bar in noisy sections (2.19 in the tail).
  - **Both:** the tail already has 18 peaks over any of these thresholds. Its problem is the ranking, not the threshold.
- **(a) fixes the cause directly.** Every ~10 minutes keeps its best moment and the total stays 23. On this game it
  changes only 2 of the 23 suggestions: the tail's best and one more go in for the two weakest elsewhere.

## Recommendation
**(a) with 10-minute slices.**
- **It fixes the cause:** the strongest-first cap ignores time.
- **No extra review:** the list stays at 23.
- **Already reviewed:** 21 of the 23 moments the founder reviewed stay the same.
- **Simple and explainable:** a parent can understand "the best moment from every 10 minutes, then the strongest of the
  rest".
- **Not 5-minute slices:** they put 2 in the tail but replace 5 suggestions, and each slice's "best" on a quiet stretch
  can be weak.

**Also worth deciding.** The near-tie at the top means that, beyond the per-slice guarantee, "strongest" is really "most
above a quiet floor". Ranking the saturated seconds by duration (how many seconds the cheer stays at the ceiling),
rather than by lift, would be a separate change. Not proposed here.
