# Spike: tap-to-follow tracking

**Date:** 2026-11-11 · **Branch:** `spike/tap-to-follow` · **Decision:** [0027](../decisions/0027-tap-to-follow-spike.md)
**Question:** tap your player on a clip's first frame. Can Apple's Vision framework keep a box on that player for
the whole clip? Success means at least 70 % of clips with no correction.

**Recommendation: no-go for this approach.** It's fast enough, but it doesn't keep the right player. I checked 6 real
clips frame by frame, and the box switched players or got lost in every one. It usually held a player for 2–7 s, then
jumped to another at a crossing, or got lost on a camera pan. The founder's 20-clip test on the iPhone is still the
deciding number; my prediction is well under 70 %. A version that could work is sketched at the end, with a size
estimate.

## How it works

Debug builds only: Settings → Debug → Tap-to-follow experiment. All the code is in `Courtside/Debug/`, inside
`#if DEBUG`.

1. **Pick a clip.** The screen loads the clip's first frame, upright. Vision's person detector
   (`VNDetectHumanRectanglesRequest`) draws a white box on everyone it finds.
2. **Tap your player.** The tap snaps to the detected person under your finger. If two boxes overlap, the smaller
   one wins, because it's usually the player further away. A tap that isn't near anyone gets an upper-body-sized
   box.
3. **Track.** The clip is decoded frame by frame with `AVAssetReader`, at up to 30 fps; frames above that are
   skipped. `VNTrackObjectRequest` (accurate level) moves the box from frame to frame. There are two modes:
   - **Tracker only:** the tap's box, followed by the tracker alone.
   - **Tracker + body re-snap** (default): every 5th frame, and whenever the tracker's confidence drops below 0.5,
     the person detector runs again. If a detected body overlaps the box by at least 30 % (IoU), the tracker
     restarts from that body. This corrects drift and size, but not identity.

   If Vision gives up (the box hits the frame edge or collapses), tracking restarts from the last box.
4. **Watch.** The clip loops with the box drawn on it. Green means the tracker is sure, yellow or red unsure, cyan
   re-snapped. Tap the video to pause. **9:16 follow** shows a full-height vertical window centred on the box. The
   window is smoothed forwards and backwards (0.4 s time constant), so it doesn't jitter or lag. It's preview only:
   nothing is exported, and `ClipExtractor` is untouched.
5. **Judge.** Press "Stayed on my player" or "Lost or switched", with a scene (open court / crowded paint) and an
   optional failure note. Each result is appended to `Application Support/Debug/tap-to-follow-log.jsonl`. The line
   holds the clip ID, processing time, frames, re-snaps, restarts, confidence and device. "Share results log" sends
   the file. The list shows the running score: the latest verdict per clip against the 70 % goal.

**Detector choice.** Vision's newer full-body mode (revision 2) found **no one** in any sideline frame tested, even
with ten players clearly visible at about a fifth of the frame's height. The older upper-body mode (revision 1)
found most of the nearer players, so the spike uses it. The box therefore follows head and torso.

## Processing time

The 13 s clips were cut from the Nov 1 test videos (4K, 30 fps) the way the app cuts them, at 1080p.

| Where | Clip | Tracker only | Tracker + re-snap |
|---|---|---|---|
| Mac (Apple silicon, Vision native) — 8 real clips | 13 s, 1080p | 1.0–1.8 s (0.07–0.14× real time) | 1.8–2.1 s (0.14–0.16×) |
| Simulator (Vision forced onto the CPU) | 13 s, 720×1280 test clip | — | 6.3 s (0.49×) |
| Simulator | 5 s, 4K real clip | — | 4.3 s (0.85×) |
| iPhone 16 Pro | — | not measured: the phone wasn't connected | — |

The Mac number is the best guide to the phone: both run Vision on the Neural Engine and GPU. I'd expect **about
2–4 s per 13 s clip on the iPhone**, but that's unverified. Every result logged on the phone records its own
processing time, so the founder's test will measure it. **Speed is not the problem**, even with 4K clips; accuracy
is.

## What happened on real footage

The tap was automated: the person nearest the middle of the first frame. Each clip was checked on a close-up sheet,
3 frames a second, cropped around the box. Clips that were viewed were deleted afterwards and nothing was saved to
the repo.

| Clip (Nov 1 video @ start) | Scene | Tracker + re-snap | Tracker only |
|---|---|---|---|
| 144828 @ 195 s | open, then crossing | ✗ #15 → crossing player at ~4 s → #10 → #11; ends on the wall | ✗ same switches |
| 144828 @ 464 s | crowded start | ✗ start box covered #15 and #4 behind him; locked onto #4 within 1 s, switched again at ~7 s | ✗ #15 → #3 at 1 s → #4 → others |
| 132814 @ 600 s | crowded | ✗ #4 → #50 within 1 s → #9 at ~8 s; ends on a spectator | not viewed |
| 151837 @ 130 s | open, one occlusion | ✗ held 6.5 s, and re-found the player after he was hidden behind a nearer one; then #55, #14 | not viewed |
| 150358 @ 400 s | open, camera pan | ✗ held #10 for ~7 s; lost on the pan (box on the wall and a spectator); back on #10 at the end | not viewed |
| 144105 @ 179 s | portrait file (players sideways, ~3 % of frame) | ✗ #4 ↔ #14, then #55 | not viewed |
| 132814 @ 300 s | — | not viewed; mean confidence 0.06, lost almost at once | 184 of 388 frames unsure |
| 144828 @ 330 s | — | not viewed; only 2 people detected in frame 1 | — |

**Result: 0 of 6 checked clips stayed on the player** (goal: 70 %). This was an automated tap, not a parent who
knows the clip, so the founder's 20 clips may do somewhat better. But the failures come from the tracker, not the
tap.

## Failure patterns (most common first)

1. **Switches at crossings and screens.** `VNTrackObjectRequest` follows a patch of pixels, not a person. When two
   players pass, it often keeps the one in front, especially a teammate in the same jersey. Players are only
   60–120 px tall in a 1080p sideline shot, so there's little detail to tell them apart.
2. **Re-snap doesn't fix identity.** It snaps to whichever detected body overlaps the box most. At a crossing that's
   often the wrong one, so it makes switches look confident: cyan boxes on the wrong player. It does stop slow drift
   and size changes, and once it helped re-find a player after an occlusion.
3. **Bad start in a crowd.** If the tapped player overlaps another in frame 1, the box covers both, and the tracker
   picks one within a second.
4. **Camera pans (handheld).** The tracker can't tell a player from the background. On a quick pan the box stays on
   the wall or the bench.
5. **Box collapses to a head**, or Vision gives up at the frame edge. Restarts are handled, but the box no longer
   frames the player well.
6. **Far side of the court.** Players under about 6 % of the frame's height are often not detected, so taps there
   get a default box and no re-snap.

The 9:16 follow preview looks calm when the box is right: smoothing hides jitter. It can't hide a switch: the window
glides over to the wrong player.

## Go / no-go

**No-go for shipping tap-to-follow on `VNTrackObjectRequest`**, with or without re-snap. It's fast, but it would fail
on most clips. The founder's 20-clip test confirms or overturns this: if it somehow reaches 70 %, revisit.

**If the feature is still wanted, the version that could work is "tracking by detection, with help from the parent":**
- Detect upper bodies on every frame (Vision, as now).
- Link each frame's detections to the player with a motion model (where he should be next) plus appearance: a
  Vision feature print (`VNGenerateImageFeaturePrintRequest`) and jersey colour from the first tap.
- When the match is weak, stop and ask instead of guessing: "Tap your player again" on that frame. A parent fixing
  one or two moments per clip is quick. A wrong automatic follow is worse than none.

All of that is still Apple frameworks only. A downloaded detection model (e.g. YOLO) would be a third-party
dependency and is ruled out.

**Size estimate**
- **Second spike** (detection + motion + appearance + one correction tap, same debug screen): **1–2 weeks** to a
  real go/no-go. The success bar should be "right player for the whole clip with at most one correction".
- **Product feature after a go: about 4–6 weeks.** It needs:
  - a spec revision, because computer vision is a listed non-goal;
  - tracking in the background, with progress and thermal limits;
  - saved tracks per clip, a SwiftData schema change with lightweight migration;
  - the correction UI;
  - the follow crop as a Vertical export option through `ExportComposer` / `ClipExtractor`, with smoothing and the
    1.5× upscale cap from [0024](../decisions/0024-vertical-zoom.md);
  - tests;
  - device performance and thermal checks.
- **Cheaper alternative with no computer vision: about 1 week.** The parent drags the 9:16 window at 2–3 moments in
  the clip, and the app glides between them. It reuses decision 0024's aim and builds the follow crop export, which
  the full feature would need anyway.

## Reproducing the numbers

- **Unit tests:** `TapToFollowTests` covers snapping, overlap, orientation, crop smoothing and the log. It also
  tracks a generated moving block in upright and rotated video, both modes.
- **Real-footage timing in the Simulator:** `TapToFollowTimingTests`, skipped unless sources are given:
  `TEST_RUNNER_COURTSIDE_TIMING_SOURCES="<video>,<video>"`. It prints `FOLLOW|` lines. Add
  `TEST_RUNNER_COURTSIDE_FOLLOW_SHEETS=<folder outside the repo>` for review sheets; delete them afterwards, because
  they show children.
- The Mac timings came from compiling `TapToFollowTracker.swift` into a throwaway command-line tool in the session
  scratchpad. It isn't part of the repo.
