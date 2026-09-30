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

## Not yet verified

- [ ] Real game **filmed on a phone camera** from the stands (landscape, with audio, 30/60 fps, rotation metadata) — the 2026-09-30 run used a screen recording
- [ ] Determinate import progress on a slow source (Files app / external drive) — Photos import is a near-instant clone
- [ ] Save Video to Photos (add-permission prompt appears only on save)
- [ ] Import from the Files app (security-scoped access)
- [ ] Insufficient-disk-space message on import
