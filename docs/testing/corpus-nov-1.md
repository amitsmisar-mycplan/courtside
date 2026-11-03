# Test corpus — Test Videos Game November 1

Source: `~/Documents/Courtside Test Videos/Test Videos Game November 1` (read-only input; videos stay out of git)
Probed 2026-11-02 with AVFoundation: every video frame's timestamp read with `AVAssetReader` (no decoding).
5 files, 15.9 GB, 51.5 minutes. Disk free at the time: 673 GB (needed 3 × 5.0 GB).

## Headline findings

1. **All five are real 30 fps** (29.95–29.99 measured as frames ÷ duration), and this time the metadata agrees:
   `nominalFrameRate` matches the measured rate on every file. 0.25× slow mo must not be offered; 0.5× should be.
2. **Not variable frame rate.** Every frame is 33.3 ms after the last (5th to 95th percentile). The only irregularity is
   one start-up gap per file: frame 2 arrives 0.20–0.21 s after frame 1. Harmless for clipping, but a mark in the first
   0.2 s has no frame of its own.
3. **One portrait recording, stored rotated.** `20261031_144105` is stored 3840×2160 with a 90° rotation tag and plays
   2160×3840 upright. This is the "phone held vertically" case the Oct 30 corpus couldn't cover.
4. **Not split recordings.** Gaps between files are 69 s to 57 min (below), so these are separate recordings, not one
   recording the camera cut into pieces. The last four (14:41–15:22) look like one game in quarters or halves.
5. **The file's creation date is when recording *ended*, not when it started.** `20261031_132814` started 13:28:14
   (filename, local time) and is stamped 20:44:29 UTC = 13:44:29 local = start + 973 s. The app uses this date for the
   game, so imported games are dated 4–16 minutes late. Not footage-related; see bugs.
6. **Large files:** 1.3–5.0 GB each, 40.8 Mbps. `20261031_132814` (5.0 GB, 16.2 min) is the largest import tested so far.

## Inventory

All Samsung phone, HEVC (`hvc1`) 3840×2160, 40.8 Mbps, AAC 48 kHz stereo. Audio covers the full length (ends ≤ 0.08 s
before the video).

| File | Size | Duration | Stored | Shown | Rotation | Real fps (frames) | nominal | Orientation |
|---|---|---|---|---|---|---|---|---|
| 20261031_132814.mp4 | 5.00 GB | 16:13.2 (973.2 s) | 3840×2160 | 3840×2160 | 0° | 29.98 (29,182) | 29.98 | landscape |
| 20261031_144105.mp4 | 1.91 GB | 6:11.8 (371.8 s) | 3840×2160 | **2160×3840** | **90°** | 29.98 (11,146) | 29.98 | **portrait** |
| 20261031_144828.mp4 | 3.46 GB | 11:13.4 (673.4 s) | 3840×2160 | 3840×2160 | 0° | 29.99 (20,192) | 29.99 | landscape |
| 20261031_150358.mp4 | 4.16 GB | 13:30.4 (810.4 s) | 3840×2160 | 3840×2160 | 0° | 29.99 (24,302) | 29.99 | landscape |
| 20261031_151837.mp4 | 1.34 GB | 4:21.2 (261.2 s) | 3840×2160 | 3840×2160 | 0° | 29.95 (7,824) | 29.95 | landscape |

Frame timing (all five): median 33.3 ms, 5th–95th percentile 33.3 ms, one 0.20–0.21 s gap after frame 1, nothing else
over 0.1 s.

Recording times (start from the filename, end = start + duration, local time Oct 31):

| File | Start | End | Gap before next |
|---|---|---|---|
| 20261031_132814 | 13:28:14 | 13:44:27 | 56 min 38 s |
| 20261031_144105 | 14:41:05 | 14:47:17 | 1 min 11 s |
| 20261031_144828 | 14:48:28 | 14:59:41 | 4 min 17 s |
| 20261031_150358 | 15:03:58 | 15:17:28 | 1 min 9 s |
| 20261031_151837 | 15:18:37 | 15:22:58 | — |

## Coverage

- [x] Large single file: 5.0 GB, 16 min (the biggest so far; Oct 30's largest was 1.3 GB)
- [x] Portrait stored with a rotation tag (90°), which Oct 30 lacked
- [x] 30 fps where the metadata tells the truth (Oct 30's files claimed 60–240 in `r_frame_rate`)
- [x] Long timeline for marking: 40+ marks across 4–16 minutes
- [ ] 60 fps source: still none. 0.25× slow mo remains untested on real footage.
- [ ] H.264 or other audio rates: all HEVC + AAC 48 kHz (Oct 30 has H.264 and 44.1 kHz)
- [ ] Full 90-minute game: the longest is 16 min

## Stress test

`CorpusStressTests` run on 2026-11-02 in the iPhone 17 Simulator (iOS 26), 09:06–11:24, 2 h 18 min, **passed**.
Run with:

```
TEST_RUNNER_COURTSIDE_CORPUS_DIR="<folder>" TEST_RUNNER_COURTSIDE_MARKS_PER_VIDEO=6 \
TEST_RUNNER_COURTSIDE_TRIMMED_CLIPS_PER_VIDEO=1 TEST_RUNNER_COURTSIDE_CORPUS_REPORT=<out.json> \
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=Courtside Tests' \
  test -only-testing:CourtsideTests/CorpusStressTests
scripts/corpus-report.py <out.json>
```

Every video hit every edge case: a mark in the first 10 s, a mark in the last 3 s, overlapping clip windows (marks
8 s apart), two marks 0.6 s apart, and the 2 s tap guard. All clips were extracted and checked; trim (widened ±5 s),
vertical 9:16 export (to a fake photo library) and delete ran on one clip per video. Each video's test data was removed
when it finished, pass or fail. The first full run (40 marks per video, about 9 h) was stopped by the founder partway
through the first video; its leftover files in the Simulator were kept on purpose.

### Results (6 marks per video)

Seed 20261101, 6 planned marks per game (+5 for the undo check, 3 undone), trim / vertical / delete on 1 clip(s) per game, clip window 10 s before / 3 s after. Timings are from the Simulator, which encodes video in software; a device's hardware encoder is much faster, so these times say nothing about speed on a phone. Peak memory over the whole run: 717 MB.

#### 20261031_132814.mp4

| Step | Result |
|---|---|
| Source | 16:13, shown 3840x2160, nominal 29.98 fps |
| Import | 2.6 s, 597 progress updates, ends at 100 %; game dated 2026-10-31T20:44:29Z |
| Marks | 6 of 6 placed by the tap code in 0 s; 1 in the first 10 s, 1 in the last 3 s, 2 neighbours < 13 s apart, 1 < 1 s apart; 2 s tap guard held |
| Undo (5 taps, 3 undos) | correct 2 kept |
| Extract | 8 clips (0 failed) in 20:12; per clip median 163.2 s, longest 169.5 s |
| Clip checks | 8 checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); largest duration error 1 ms |
| Slow mo, clip @7.00 s (0.00–10.00 s) | real 29.60 fps, app reads 29.60; offered: 0.5× |
| Slow mo, clip @437.95 s (427.95–440.95 s) | real 30.15 fps, app reads 30.15; offered: 0.5× |
| Trim + vertical + delete, clip @584.00 s | trim 13.0→23.0 s in 295.4 s; vertical export 114.2 s; deleted |
| Orphans after deletes | none |
| Disk | 4995 MB after import, peak 5191 MB; all removed at the end |
| Peak memory | 695 MB |
| Failures | 0 |

#### 20261031_144105.mp4

| Step | Result |
|---|---|
| Source | 6:12, shown 2160x3840, nominal 29.98 fps |
| Import | 1.1 s, 229 progress updates, ends at 100 %; game dated 2026-10-31T21:47:18Z |
| Marks | 6 of 6 placed by the tap code in 0 s; 1 in the first 10 s, 1 in the last 3 s, 2 neighbours < 13 s apart, 1 < 1 s apart; 2 s tap guard held |
| Undo (5 taps, 3 undos) | correct 2 kept |
| Extract | 8 clips (0 failed) in 22:21; per clip median 177.3 s, longest 184.0 s |
| Clip checks | 8 checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); largest duration error 1 ms |
| Slow mo, clip @7.00 s (0.00–10.00 s) | real 29.50 fps, app reads 29.43; offered: 0.5× |
| Slow mo, clip @167.31 s (157.31–170.31 s) | real 30.15 fps, app reads 30.15; offered: 0.5× |
| Trim + vertical + delete, clip @167.31 s | trim 13.0→23.0 s in 269.5 s; vertical export 127.6 s; deleted |
| Orphans after deletes | none |
| Disk | 1908 MB after import, peak 2102 MB; all removed at the end |
| Peak memory | 696 MB |
| Failures | 0 |

#### 20261031_144828.mp4

| Step | Result |
|---|---|
| Source | 11:13, shown 3840x2160, nominal 29.99 fps |
| Import | 1.5 s, 413 progress updates, ends at 100 %; game dated 2026-10-31T21:59:42Z |
| Marks | 6 of 6 placed by the tap code in 0 s; 1 in the first 10 s, 1 in the last 3 s, 2 neighbours < 13 s apart, 1 < 1 s apart; 2 s tap guard held |
| Undo (5 taps, 3 undos) | correct 2 kept |
| Extract | 8 clips (0 failed) in 20:52; per clip median 157.2 s, longest 180.3 s |
| Clip checks | 8 checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); largest duration error 1 ms |
| Slow mo, clip @7.00 s (0.00–10.00 s) | real 29.60 fps, app reads 29.60; offered: 0.5× |
| Slow mo, clip @303.01 s (293.01–306.01 s) | real 30.08 fps, app reads 30.08; offered: 0.5× |
| Trim + vertical + delete, clip @202.60 s | trim 13.0→23.0 s in 277.2 s; vertical export 99.6 s; deleted |
| Orphans after deletes | none |
| Disk | 3456 MB after import, peak 3660 MB; all removed at the end |
| Peak memory | 698 MB |
| Failures | 0 |

#### 20261031_150358.mp4

| Step | Result |
|---|---|
| Source | 13:30, shown 3840x2160, nominal 29.99 fps |
| Import | 2.0 s, 497 progress updates, ends at 100 %; game dated 2026-10-31T22:17:29Z |
| Marks | 6 of 6 placed by the tap code in 0 s; 1 in the first 10 s, 1 in the last 3 s, 2 neighbours < 13 s apart, 1 < 1 s apart; 2 s tap guard held |
| Undo (5 taps, 3 undos) | correct 2 kept |
| Extract | 8 clips (0 failed) in 21:22; per clip median 168.3 s, longest 178.6 s |
| Clip checks | 8 checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); largest duration error 1 ms |
| Slow mo, clip @7.00 s (0.00–10.00 s) | real 29.40 fps, app reads 29.40; offered: 0.5× |
| Slow mo, clip @364.69 s (354.69–367.69 s) | real 30.08 fps, app reads 30.08; offered: 0.5× |
| Trim + vertical + delete, clip @365.99 s | trim 13.0→23.0 s in 281.5 s; vertical export 107.9 s; deleted |
| Orphans after deletes | none |
| Disk | 4159 MB after import, peak 4354 MB; all removed at the end |
| Peak memory | 705 MB |
| Failures | 0 |

#### 20261031_151837.mp4

| Step | Result |
|---|---|
| Source | 4:21, shown 3840x2160, nominal 29.95 fps |
| Import | 0.6 s, 161 progress updates, ends at 100 %; game dated 2026-10-31T22:22:59Z |
| Marks | 6 of 6 placed by the tap code in 0 s; 1 in the first 10 s, 1 in the last 3 s, 2 neighbours < 13 s apart, 1 < 1 s apart; 2 s tap guard held |
| Undo (5 taps, 3 undos) | correct 2 kept |
| Extract | 8 clips (0 failed) in 20:09; per clip median 154.3 s, longest 181.3 s |
| Clip checks | 8 checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); largest duration error 0 ms |
| Slow mo, clip @7.00 s (0.00–10.00 s) | real 28.90 fps, app reads 28.85; offered: 0.5× |
| Slow mo, clip @117.55 s (107.55–120.55 s) | real 29.92 fps, app reads 29.88; offered: 0.5× |
| Trim + vertical + delete, clip @78.60 s | trim 13.0→23.0 s in 296.2 s; vertical export 110.2 s; deleted |
| Orphans after deletes | none |
| Disk | 1340 MB after import, peak 1533 MB; all removed at the end |
| Peak memory | 717 MB |
| Failures | 0 |

#### Totals

| | |
|---|---|
| Videos | 5 (51:30 of footage) |
| Import | 8 s in total |
| Clips | 40 made, 0 failed, 40 checked |
| Clip time | 104:56 in total; median 161.2 s per clip |
| Failures | 0 |

#### Failures

None.

### Trial run (10 marks, one video)

`20261031_151837`, 10 marks + 3 trimmed clips: 12 of 12 clips in 24:07, 0 failures, largest duration error 0 ms,
trims 99.8 / 280.7 / 215.0 s, vertical exports 35.5 / 90.0 / 87.5 s, peak memory 695 MB, no orphans. Its first clip
(tap at 1.0 s, window 0:00–0:04) measured **27.25 fps**, so no slow mo was offered: bug 1 below.

### Bugs found

Ranked by risk of losing or corrupting footage. None loses or corrupts footage: every imported copy had exactly the source's
size, every clip matched its window to within 1 ms, and nothing was orphaned after trims and deletes.

| # | Bug | Footage risk | Evidence |
|---|---|---|---|
| 1 | Long extraction holds a background task past iOS's 30 s allowance. The log warns `Background Task "ClipExtraction" was created over 30 seconds ago … risk of termination` (5 times, once per game). If the parent leaves the app mid-extraction, iOS may kill it. | Low. The game video is never touched; an interrupted clip leaves a `.partial` that launch cleanup sweeps, and unextracted marks stay marked. Lost work, not lost footage. Worth checking on the device. | run6 log |
| 2 | Slow mo is not offered on a clip that starts at 0:00 and is short, on 30 fps footage. Every phone file has a 0.2 s start-up gap after frame 1; in a 4 s window that drags the measured rate to 27.25 fps, under the 28 fps cutoff for 0.5×. With a 10 s window (tap at 7 s) it reads 28.9–29.6 fps and 0.5× is offered, but 151837 came within 0.9 fps of the cutoff. Extends open question 4. | None. Only a missing feature on the first seconds of a game. | trial: 27.25 fps; run6 first clips 28.85–29.60 |
| 3 | Imported games are dated when the recording **ended**, not when it started: the app uses the file's creation date, which Samsung stamps at the end. Games are 4–16 min late (132814 shows 13:44 for a 13:28 start). | None. Display and sort order only. | `importedCreatedAt` per video above |

Bugs 1 and 2 were fixed on 2026-11-02 ([0017](../decisions/0017-background-clip-resume.md),
[0018](../decisions/0018-frame-rate-from-frame-gaps.md)); bug 3 is open.

Not bugs:

- The Simulator log shows `VTCompression … err=-12900` 50 times. It's software-encoder noise; every export still
  succeeded and passed its checks.
- Correction to `corpus-oct-30.md`: it says rotation is 0° on every file, but `DJI_20261004_103320_13` is stored
  1080×1920 with a 90° tag (and `20261007_165634` has 90°). Docs only; the app handles both.
