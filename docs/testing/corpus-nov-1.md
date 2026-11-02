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

Results from `CorpusStressTests` are below, once run.
