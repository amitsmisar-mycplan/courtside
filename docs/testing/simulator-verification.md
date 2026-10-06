# Simulator verification (steps 1–5)

## Automated tests — 20/20 passing

```
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `ClipWindowTests` — all five spec cases (t=2s clamp, 1s before end, exactly 0, exactly duration, zero-length game) plus nudge and settings clamping
- `StorageManagerTests` — relative filenames only, backup exclusion on `Games/` and `Clips/`
- `ClipExportTests` — real HEVC export of a generated, rotated video: duration within 0.1 s, rotation preserved (gotcha #7), first frame within one frame of target

## Manual walkthrough — 2026-09-26, iPhone 17 Simulator, iOS 27

Test material: 5-minute generated video with a timecode on every frame.

| Check | Result |
|---|---|
| Import from Photos, copied into `Documents/Games/` | ✅ |
| `Games/` has backup-exclude attribute | ✅ |
| Duration correct (5:00); label uses embedded creation date | ✅ |
| Marking screen landscape-locked, playing | ✅ |
| Marks at 1×, 1.5×, 2×; ticks on scrub bar | ✅ |
| Debounce: two quick taps → one mark | ✅ |
| Undo removes the last mark | ✅ |
| Control strip taps don't place marks | ✅ |
| 5 clips extracted, windows = [mark − 10 s, mark + 3 s] | ✅ |
| Frame 10 s into each clip shows the tapped timecode | ✅ (all 5, incl. 2× marks) |
| Keep/Delete prompt with size | ✅ |
| Detail grid with midpoint thumbnails | ✅ |
| Nudge end +1 s: same file replaced, thumbnail regenerated | ✅ |
| Share sheet opens | ✅ |
| Delete game removes video, clips, thumbnails, rows | ✅ |

Fixed during the walkthrough: game page briefly laid out in landscape after Done; redundant Cancel on the Keep/Delete alert.

## Full-length run — 2026-09-30, iPhone 17 Simulator

Test material: a 55:35 phone **screen recording of a YouTube stream** of a youth game (1.89 GB, H.264,
portrait 1080×2316, ~23 fps, no audio). The game fills a band across the middle of the frame; the last minutes are
YouTube's "More videos" page. Kept private in `~/Documents/Courtside Test Videos/` — not in git, not shared.

| Check | Result |
|---|---|
| Import 1.89 GB from Photos | ✅ ~10 s (same-volume clone, so the progress bar barely shows) |
| Duration and label | ✅ 55:35; label "Game — Sep 10, 2026" from the recording date |
| 20 marks spread over 0:11–43:20, 12 at 1× then 8 at 2× | ✅ 20 ticks, count 20, Undo shown after each |
| 2 s debounce | ✅ rapid taps were collapsed (had to pace test taps ≥ 2 s apart) |
| Extract 20 clips | ✅ 20/20, 0 failures, no partial files left; **7 min 49 s** total (~23 s/clip, software HEVC) |
| Clip windows and length | ✅ every clip exactly [mark − 10 s, mark + 3 s], 13.00 s |
| Portrait preserved | ✅ every clip 1080×2316, same framing as source |
| Each clip contains the tapped moment | ✅ 19/20 matched the source frame at the mark exactly; the 20th is on a static screen (source frames identical ±2 s), so it can't be distinguished — window and duration correct |
| Keep = forever | ✅ Keep stored `keepsVideo`; game page shows "is kept. Delete…"; no expiry |

**Finding:** portrait videos are tiny in the landscape-locked marking screen — the whole portrait frame is fitted into
the landscape height, so the game is a small strip. See [open question 3](../status/open-questions.md).

## Slow motion — 2026-10-01, iPhone 17 Simulator

Test material: generated games with an on-screen timecode, a moving ball and a 440 Hz tone — 60 fps landscape,
30 fps portrait, 24 fps (in `~/Documents/Courtside Test Videos/Synthetic/`). Your spec's seven steps:

| # | Check | Result |
|---|---|---|
| 1 | 60 fps clip → 0.25× render | ✅ 23.50 s (= 13 − 3.5 + 14); frames land where the math says — 16 s into the render shows the tapped moment; audio tone → **silence** (rms 0.000) through the slow part → tone; landscape transform kept |
| 2 | 30 fps → 0.25× disabled, 0.5× works | ✅ "This video was recorded at 30 fps, so 0.25× isn't available."; 0.5× render 6.00 s, **portrait rotation identical to source** |
| 3 | 24 fps → slow mo disabled | ✅ "…24 fps, which doesn't have enough frames for slow motion." No controls, no empty preview |
| 4 | Drag segment to both clip edges | ✅ clamps to 0.0–13.0 s; dragging clears the stale preview |
| 5 | Delete clip | ✅ clip file, slow-mo file, thumbnail and row all removed |
| 6 | Re-render at another speed | ✅ 0.25× → 0.5×: only the new `-slowmo-0.5.mov` remains |
| 7 | Preview ×10 without rendering | ✅ memory flat at 398–403 MB (one-time +17 MB on first preview for the decoder) |

Also checked: migration of the existing 20-clip store (6 new columns, all rows intact); new clips store `markSeconds`;
default slow window 8.0–11.5 s centred on the tap; storage totals include slow-mo files; Original / Slow Mo toggle.

**Bugs found and fixed during this run**
- Slow Mo sheet stuck on "Checking the video…" — the session was never asked to read the frame rate.
- Rendering a clip that is slowed **end to end with sound** failed ("couldn't be exported"): the audio track would be
  nothing but silence. Now the render has no audio track in that case. Regression test added.
- Polish: "Save Slow Mo" label wrapped (now "Save"); empty preview shown at 24 fps; "1 marks" / "1 Clips".

## Real camera footage — 2026-10-06, iPhone 17 Simulator

17 videos shot Oct 4 (15 phone: 4K landscape ~30 fps with audio, 1.5 s – 4.5 min; 2 DJI: 1080p 30 fps stored sideways with a
rotation flag). Kept in `~/Documents/Courtside Test Videos/` — not in git. Resulting clips copied to `Clips - Oct 4 test/`.

| Check | Result |
|---|---|
| Import 875 MB 4K video | ✅ ~2 s |
| DJI rotation (stored 1080×1920, shows 1920×1080) | ✅ plays upright in marking, clip player, clips and slow mo |
| Clip export, DJI 1080p | ✅ 2 clips in 104 s, 30 fps, audio kept |
| Clip export, phone 4K | ✅ 13 s 4K clip in **120 s** (software HEVC — device will be much faster), 24 MB |
| 1.5 s video, tap at its end | ✅ one clip covering the whole video (0–1.51 s), no error |
| Slow mo, 30 fps footage | ✅ 0.5× only, with the 30 fps explanation |
| Slow mo render, real footage | ❌ → ✅ failed with -16364; fixed by H.264 fallback ([decision 0009](../decisions/0009-slowmo-h264-fallback.md)). DJI and 4K renders: 16.5 s, rotation kept, **real gym audio** before/after, silent during |
| Slow mo, 1.5 s clip | ⚠️ switched off with "recorded at 26 fps" — the phone shot 30 fps; very short clips under-report. Accepted as is (open question 4) |
| Incomplete file (`…111052.mp4`, first transfer) | Detected outside the app (no index/`moov` box); the re-sent copy is fine |

**Finding:** none of the parent's footage is 60 fps, so 0.25× never appears with it (phones default to 4K30).

## Not yet verified

- [ ] Real game **filmed on a phone camera** from the stands (landscape, with audio, 30/60 fps, rotation metadata) — the 2026-09-30 run used a screen recording
- [ ] Determinate import progress on a slow source (Files app / external drive) — Photos import is a near-instant clone
- [ ] Save Video to Photos (add-permission prompt appears only on save)
- [ ] Import from the Files app (security-scoped access)
- [ ] Insufficient-disk-space message on import
- [x] Slow motion on real phone footage (30 fps, real audio) — 2026-10-06
- [ ] Slow motion on 60 fps phone footage; whether real iPhones need the H.264 fallback
