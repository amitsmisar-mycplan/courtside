# 0033 — Auto-follow for Vertical exports (on-device motion analysis)

**Status:** Accepted · 2026-11-18 (founder's "Auto-follow for Vertical exports" spec). Builds on
[0024](0024-vertical-zoom.md), [0028](0028-aim-keyframes.md) and [0032](0032-framing-presets.md). No schema change:
auto points live in the existing `AimTrack` with its reserved `origin: .automatic`.

## Approval: an exception to the computer-vision non-goal
The founder approved this exception in writing on 2026-11-18. It covers **on-device motion analysis only**: frame
differencing (or optical flow) on the video's pixels. It does **not** allow ML models, player or face recognition,
stats, cloud, or third-party dependencies, and it does not widen [0027](0027-tap-to-follow-spike.md) or
[0029](0029-find-moments.md). CLAUDE.md is unchanged; this record is the exception.

## Why
Parents won't learn Add Aim Point. Vertical's fixed center crop cuts off the shooter when the basket is near a side.
The default has to give a good vertical clip with no setup.

## Decision
- **Analyzer** (`Processing/MotionAnalyzer.swift`). Reads the clip file once with `AVAssetReader` and keeps about 4
  frames a second as a 160-pixel-wide grayscale copy, as shown (rotation applied). For each frame against the one before:
  - **Camera pans.** A pan is undone first: the background shift is found by matching the two copies (zero unless a
    shift lines them up clearly better). This was added after the first look at real footage, which comes from a panning
    auto-tracking camera rather than a tripod.
  - **What counts as motion.** A pixel is moving when it changed both on screen and against the lined-up background
    (within a pixel). So a scoreboard overlay fixed to the screen doesn't look like motion while the court slides under it.
  - **Ignored areas.** The outer strips are left out: 6 % at each side, 8 % top and bottom. So are spots in the top
    or bottom quarter that move in more than 60 % of frames (a running clock or a video board).
  - **No reliable motion.** Fewer than 0.2 % of pixels moving means nothing to follow; more than 35 % means the camera
    moved too much. Either way the sample is empty.
  - **Finding the middle of the play.** Each frame's motion across the width is pooled with the 2 frames on each side
    (about 1.25 s). The middle is the weighted center of the densest 40 %-wide stretch, so a lone mover (a ref, a sub)
    doesn't pull it away from the group. The result is a time series of center points.
- **Aim points** (`Processing/AutoAim.swift`, pure). Built under the existing `AimPath` rules:
  - **Smoothing.** Gaps are filled from their neighbors, then a 5-sample median (drops brief outliers) and a light mean.
  - **Choosing points.** Start with one aim at the median, then greedily add the point that most reduces the time the
    action spends more than a quarter of the window from its middle. At most `AimTrack.manualLimit` (5) points, at least
    1 s apart, each added only if it helps by 0.3 % of the width; then each aim is nudged.
  - **Speed cap and stored aims.** Eased glides and the 1-window-width-per-second cap come from `AimPath.motion`.
    What's stored is where the window really goes, so the editor shows the points as they play.
  - **Fallback.** Too little motion (fewer than 3 samples, or under a quarter of the clip) gives one centered aim:
    today's behavior.
- **Storage.**
  - **The points.** Auto points are an `AimTrack` with `origin: .automatic` on the clip, in game-video seconds like
    manual ones.
  - **Hand edits.** Moving, adding, deleting or re-timing a point makes the track `.manual` and keeps the points to edit.
  - **Switching off.** Turning auto-follow off stores one centered manual point, a recorded choice so it doesn't turn
    itself back on next time. A plain centered aim otherwise still stores nothing, as in 0028.
- **Cache** (`StorageManager`, MomentScans pattern). `Caches/MotionScans/<clip id>-<file name>.json` holds the samples
  (numbers only), checked against the file's size so a trim or a new slow-mo render is scanned again. It is removed:
  - with the clip, its game, or its slow-mo version;
  - by the launch sweep, for clips that no longer exist.
  No absolute URLs are stored.
- **Running.** `MotionScanQueue` runs one scan at a time, off the main thread, cancellable (closing the sheet, a hand
  edit, or turning it off cancels it). The sheet shows "Finding the action… N%" and holds Save until it's done. It reads
  only the clip file, so recorded and imported games are treated the same; nothing branches on `Game.source`.
- **Vertical screen.** An "Auto-follow" switch under the play row, with one line of copy:
  - **On:** "Follows the action automatically. Adjust if it's off."
  - **Off:** 0028's two numbered steps.
  - **Failed scan:** "Couldn't find the action in this clip, so the frame is centered."
  - **Side warning:** shown on Tight, or with one aim point when auto-follow is off.
  - **Zoom:** Wide / Medium / Tight still sets it; the auto points are worked out again at the new zoom.
  - **Layout:** 0025's rules apply; the video box is the same height as before on both test phones.
- **Export.** Unchanged: auto points are aim points, so `ClipExtractor` → `ExportComposer` and 0028's per-frame
  placement are the only export code. One zoom per export.
- **Default.** On for a clip with no stored aim (`AutoFollowSettings.isOnByDefault`), per the evaluation below.

## Evaluation (the default rule)
The founder's rule: on by default only if it keeps the play in frame in clearly more sampled frames than the center crop,
and is worse in no more than 1 of the 8+ moments.

**How it was run.**
- **Exports.** Every moment was exported at Medium twice through `ClipExtractor`, once with auto-follow and once
  centered (`AutoFollowEvaluationTests`, "Courtside Tests" Simulator).
- **Sources.** The founder's 16 marked clips of Northwood vs Tesoro (13 s, 1080p), a 16 s dead-ball stretch cut from
  that game, and the 16.9 s 4K IMG_0061 video.
- **Data handling.** All were read from the founder's "iPhone 17" Simulator data without installing anything there.
  Every export and frame stayed outside the repo and was deleted afterwards.
- **Counting.** One frame a second was sampled from each export and the source, with both crops drawn on the source
  frame. A frame counts when the ball handler or shooter and the nearby play are inside the crop.
- **Freezing the algorithm.** It was frozen after one change (the 1.25 s pooling), made after looking at 2 clips' crops
  and before any counting.

| Moment | What happens | Frames | Center in frame | Auto in frame |
|---|---|---|---|---|
| c41 | Fast break to the left basket | 13 | 11 | 12 |
| c43 | Transition both ways | 13 | 10 | 11 |
| c53 | Rebound at the right basket, break left, dead ball | 13 | 6 | 10 |
| c50 | Fast break, made shot at the right basket | 13 | 6 | 13 |
| c52 | Made 3 at the right basket | 13 | 4 | 13 |
| c47 | Fast break, made 3 at the left basket | 13 | 9 | 12 |
| c45 | Made shot at the left basket, end of quarter | 13 | 12 | 12 |
| c46 | Made 3 from the left wing | 13 | 11 | **8** |
| c54 | Half-court set at the right basket | 13 | 3 | 13 |
| c51 | Half-court set at the right basket | 13 | 2 | 13 |
| c49 | Half-court set, drifting right | 13 | 6 | 13 |
| c48 | Half-court, made 3 | 13 | 10 | 10 |
| c42 | Half-court set near the right side | 13 | 10 | 12 |
| c44 | Steal, break, score at the left basket | 13 | 11 | 11 |
| c39 | Opening possession | 13 | 10 | 12 |
| c40 | Play at the left basket | 13 | 13 | 13 |
| dead ball | Stoppage at 29:12, players standing at center | 16 | 16 | 16 |
| IMG_0061 | Handheld, 16.9 s, ends with a shot at ~14 s | 17 | 17 | 17 |
| **Total** | 18 moments | **241** | **167 (69 %)** | **221 (92 %)** |

**Result: on by default.**
- **Frames in.** 221 against 167.
- **Worse in 1 of 18 moments:** c46. Fans moving in the near bleachers on the left pulled the crop left for 5 s while
  the play was in the middle and right.
- **Close calls.** A ref or someone on the bench near the camera pulled the crop toward them in c40 and c41, but not out
  of the play.
- **Biggest wins.** Half-court sets near one basket (c49, c51, c52, c54): center crop shows the middle of the floor
  while the play is at the side.
- **IMG_0061.** It is handheld, so the person filming already kept the play centered; both crops are nearly the same.
  The shot at ~14 s is at the basket the camera faces, not near the right edge as the spec expected.

**Caveats.**
- **Not tripod footage.** This is footage from a panning auto-tracking camera (XbotGo), not the tripod footage the
  feature targets. The center crop is a strong baseline there, because the camera already centers the play.
- **One reviewer.** The counts are one reviewer's judgment from small frames: the ball often isn't visible, so "the
  play" was judged by where the players around it were.
- **Not a held-out set.** The algorithm was built and evaluated on the same game.

## Cost
Scan time per clip, debug build, Simulator (the Simulator uses the Mac's CPU, so these say little about a phone):

| Clip | "Courtside Tests" (iPhone 17 Pro) | "Courtside Tests SE" |
|---|---|---|
| 13 s at 1080p (16 clips) | 2.7–4.4 s, median 3.2 s | 2.8–9.2 s, median 3.1 s |
| 16.9 s at 4K (IMG_0061) | 4.4 s | 6.6 s |
| 16 s at 1080p (cut from the game) | 7.6 s | 4.3 s |

The SE outliers (7–9 s) happened while the other Simulator was exporting.

**Battery and heat.** A scan decodes the clip once, and the clip is the 13–16 s export, not the full game. It keeps a
small grayscale copy of 4 frames a second and does integer math on 160×90 pixels. That is a small fraction of the work
of one Vertical export of the same clip (about 60–80 s in the Simulator). The saved scan means opening the screen again
doesn't rescan. Heat or battery risk for 16 s clips should be negligible; the phone hasn't been measured.

## Tradeoffs
- Large motion near the camera (fans, a bench, a ref walking past) can pull the crop off the play; that was the one loss.
- A camera that zooms in and out isn't undone (only pans are), so the zoom shows as motion near the edges.
- Turning auto-follow on replaces hand-set points without asking.
- Points follow motion, not the ball. On a clip where everyone stands still, the frame centers.
