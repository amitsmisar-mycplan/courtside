# Test corpus — Test Clips Oct 30

Source: `~/Documents/Courtside Test Videos/Test Clips Oct 30`
Probed 2026-10-30 with ffprobe. 27 files, ~11.5 GB.

## Headline finding: every file is 30fps, but the metadata lies

`r_frame_rate` reports 30, 60, 120 or 240 depending on the file. **Actual measured
frame rate is ~30fps for all 27.** Verified by counting packets:

| File | r_frame_rate claims | Actual frames ÷ duration |
|---|---|---|
| 20261014_163009.mp4 | 240 | 29.98 |
| 20261004_105657.mp4 | 59.94 | 29.80 |
| 20261004_111052.mp4 | 120 | 29.87 |
| DJI_20261007_173541_18 | 120 | 30.00 |

These are variable-frame-rate recordings. `r_frame_rate` is the timebase tick rate, not
the capture rate.

**Impact on the slow-motion feature:** the spec gates available speeds on the track's
reported frame rate. If `AVAssetTrack.nominalFrameRate` follows the same inflated
metadata, the app will offer 0.25x on files with only 30 real frames per second, and the
output will stutter badly. **Do not trust nominalFrameRate alone.**

Fix: derive an effective frame rate from frame count ÷ duration, or at minimum
cross-check `nominalFrameRate` against `CMTimeGetSeconds(track.minFrameDuration)` and
take the more conservative value. Gate slow-mo on the measured number.

This also means **no file in this corpus can currently test the 60fps / 0.25x path.**
That path stays unverified until live capture exists on a device.

## Inventory

**Samsung 4K set (20 files)** — 3840x2160, HEVC, landscape, AAC 48kHz stereo
Durations 14.5s – 268.8s. Sizes 71 MB – 1315 MB.

**DJI set (7 files)** — 1080x1920, H.264, **natively portrait**, AAC 44.1kHz stereo
Durations 6.4s – 449.9s. Sizes 7 MB – 460 MB.

Rotation side-data is 0 on every file in both sets.

## Coverage

- [x] Large single file — 1.3 GB (20261004_130544.mp4, 4.5 min)
- [x] 30fps — all of them; 0.25x must be disabled, 0.5x available
- [x] Portrait — the DJI set, natively encoded portrait
- [x] 4K — the entire Samsung set
- [x] Very short clip — DJI_20261007_173820_19 at 6.4s; clip window must clamp at both ends
- [x] H.264 and HEVC both present
- [x] Two different audio sample rates (48kHz and 44.1kHz)
- [ ] **60fps source** — none. 0.25x slow-mo path is untestable here.
- [ ] **Full-length game** — longest real clip is 7.5 min. See note below.
- [ ] **Rotation metadata ≠ 0** — the DJI files are natively portrait rather than
      landscape-with-rotation, so the sideways-export bug class is NOT covered. Phone
      footage shot vertically usually carries rotation=90 on a 1920x1080 stream.
      Needs a test file from an iPhone held vertically.

### Full-length import

The only long file in the wider test tree is
`Courtside Test Videos/Screen_Recording_20260910_115828_YouTube.mp4` — 55.6 minutes.
It's a screen recording, not game footage, but it is valid for testing import progress,
memory behaviour during the copy, and marking across a long timeline. Use it for that and
nothing else.

## Duplicates

`20261004_130544.mp4`, `20261004_110141.mp4` and `20261004_104520.mp4` appear in at least
three folders each (`Test Clips Oct 30`, `My clips`, and the tree root). Worth
deduplicating — the whole tree is 23 GB across 84 video files.

## Test order

1. `DJI_20261007_173820_19_null_video.mp4` — 6.4s, 7 MB. Clamping at both ends.
2. `DJI_20261004_103320_13_null_video.mp4` — portrait, 2.4 min. Orientation on export.
3. `20261004_130544.mp4` — 1.3 GB, 4.5 min, 4K. Import stress.
4. `20261004_111052.mp4` — metadata claims 120fps, actually 30. **Slow-mo gate must
   refuse 0.25x on this file.** This is the regression test for the finding above.
5. Everything else.
