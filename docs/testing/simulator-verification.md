# Simulator verification (steps 1–5)

## Automated tests — 20/20 passing

```
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=Courtside Tests' test
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

## 2026-10-30 — Oct 7 / Oct 14 footage, unplayable-video notice

14 new videos (Oct 7: 3 phone + 5 DJI; Oct 14: 6 phone), all 30 fps. Kept in
`~/Documents/Courtside Test Videos/Test Clips Oct 30/` — not in git.

| Check | Result |
|---|---|
| Upright phone video (`20261007_165634`, stored 3840×2160 with a 90° rotation) | ✅ plays upright in marking; 4 clips made, upright |
| Simulator lost its audio device (error -66680 → AVPlayer -11800/-12746) | Black marking screen with a *pause* button, no message. Simulator-only; fixed by restarting the Simulator |
| Same failure, after the fix | ✅ "This video can't be played right now — Nothing has been deleted…"; taps don't place marks. Checked with a broken stand-in file; the real video was set aside and restored |

## Full-screen slow-mo preview — 2026-10-30, iPhone 17 Simulator

Decision [0012](../decisions/0012-slowmo-fullscreen-preview.md). Footage from `Test Clips Oct 30` (not in git), one
clip each. Note: `DJI_20261004_103320_13` is stored 1080×1920 with a 90° rotation tag, so it *shows* landscape; the
portrait cases are `20261007_165634` (phone, shows 2160×3840) and `DJI_20261007_173820_19` (1080×1920, no rotation).

| Check | Result |
|---|---|
| Poster in the sheet | ✅ frame at the tap, real shape: portrait posters tall (height capped), landscape 16:9 |
| Portrait phone clip (`20261007_165634`) | ✅ stays portrait, fills the width edge to edge, no letterbox |
| 6.4 s portrait DJI clip (`…173820_19`) | ✅ fills portrait; slow part 1.3–4.8 s so it starts from 0; loops (10 s output, still playing 13 s later from the start) |
| 4K landscape (`20261004_130544`) | ✅ screen turns to landscape by itself, fits without cropping; back to portrait on close |
| Rotation-tagged DJI (`…103320_13`) | ✅ treated as landscape, upright |
| Tap to pause / resume | ✅ portrait and landscape; pause symbol stays while paused |
| Close → editor | ✅ speed, slow part, everything unchanged |
| Reopen, same settings | ✅ instant (same item), restarts before the slow part |
| Change the slow part, reopen | ✅ new composition plays the new segment |
| Change speed | Not possible on this footage (all 30 fps → 0.5× only); covered by `SlowMoPreviewTests` with a 60 fps clip |
| Memory across opens (4K clip, `footprint`) | 104 MB before → 121 MB after 5 opens → 133 MB after 5 rebuilds → **123 MB after 15**; 121 MB with the sheet closed. Flat — no growth per open |

One preview tap in the very first session didn't pause; not reproduced in later tries (several first taps worked). The
Simulator's screenshots lag the screen by a moment, which explained a similar "missed" mark tap. Watch for it on the device.

## Game library — 2026-10-30, iPhone 17 Simulator

Decision [0013](../decisions/0013-game-library.md).

| Check | Result |
|---|---|
| v1 store upgrade (4 games, 9 clips, marks, slow-mo names) | ✅ backed up, installed over it: every game, mark and clip identical; 4 new columns, all empty |
| Existing names | ✅ still shown as titles ("Game — Oct 4, 2026") |
| Edit: opponent, score, notes | ✅ opponent field ready to type; Next → score (number pad); row shows "vs Lakers  54–48" |
| Details survive relaunch | ✅ force-quit and relaunch: opponent, score, notes kept (also read straight from the store) |
| Import creates a game | ✅ created before any question; date from the video (Oct 14); "Later" → "Untitled game", newest first |
| Swipe to delete | ✅ confirmation names the clips; the game's video file removed, other 4 games' files and 9 clips untouched |
| Empty state | ✅ fresh iPhone 18 Pro Simulator: message + "Record a Game" + "Import a Video" (Files / Photos menu) |
| Recording creates a game | Unit test (no camera in the Simulator): created untitled, before any footage is at risk |

## Undo and clip delete — 2026-10-30, iPhone 17 Simulator

Decision [0014](../decisions/0014-undo-stack-and-clip-delete.md).

| Check | Result |
|---|---|
| Tap 5, undo 3 (playback marking) | ✅ button "Undo 5" → three taps → the last three marks removed, first two kept (read from the store) |
| Same on a recorded game | Unit test only (no camera in the Simulator); same code path |
| Swipe a clip → Delete | ✅ record and clip file removed |
| Select 2 → Delete | ✅ "Delete 2 clips?" confirmation; both files gone, no leftover files (thumbnails included); other games' 6 clips untouched |

Simulator note: taps sent within ~1 s of a screen appearing, or right after a relaunch, are sometimes dropped by the
Simulator's input connection. Pace scripted taps; check on a device.

## Trim a clip — 2026-10-30, iPhone 17 Simulator

Decision [0015](../decisions/0015-clip-trim.md). Test clip on the 4:28 Oct 4 game: tap at 0:11.8, clip 0:01.8–0:14.8.

| Check | Result |
|---|---|
| Trim screen | ✅ frame strip 0:00–0:26.8 (30 s before the tap clamped to the video start; 15 s after), handles, tap line, "13.0 sec", "10.0 s before · 3.0 s after"; Save and Reset off until something changes |
| Drag past the start / end | ✅ stops at 0:00 and at tap + 15 s → 26.8 s |
| Drag the end onto the start | ✅ stops at 2.0 sec |
| Dragging exports nothing | ✅ clip file unchanged (size and date), no `.partial` file |
| Reset to Default | ✅ back to 10 s / 3 s; Save off again |
| Save (end +5 s) | ✅ progress bar, Cancel off; ~3.5 min for 4K in the Simulator. Range 0:01.8–0:19.8, tap unchanged, same filename, 25.9 → 35.7 MB, file count unchanged, no `.partial` |
| Relaunch | ✅ clip shows 0:01–0:19 · 18 sec with a new thumbnail; the file is 18.02 s |
| Full game video gone | ✅ Trim disabled: "The full game video was deleted, so this clip can't be trimmed." (flag set briefly in the store, then restored; no file touched) |

## Save to Photos — 2026-10-30, iPhone 17 Simulator

Decision [0016](../decisions/0016-export-to-photos.md).

| Check | Result |
|---|---|
| Permission prompt | ✅ add-only, shown on first save before any rendering, with the new usage text |
| Don't Allow | ✅ "Courtside can't save to Photos" + Open Settings (opens Settings); nothing rendered, no temp file |
| Vertical, 13 s upright phone clip (9:16, 4K) | ✅ **46 s**; 1080×1920 HEVC, 13.00 s video, audio 0.00–12.96 s; fills the frame, upright |
| Vertical, 18 s landscape 4K clip | ✅ **70 s**; 1080×1920, video fit to width over a blurred copy, audio 0.00–17.99 s |
| Original | ✅ ~1 s, the clip file itself (3840×2160), not re-encoded; clip kept |
| Cancel at 18 % | ✅ back to the format choice; temp folder empty (export + partial gone); nothing added to Photos |
| Temp files after save | ✅ `tmp/Exports` empty |
| Sheet label | ✅ Original says "9:16" with a tall icon for an upright clip, "16:9" for landscape |

Simulator encoding is software; a device should be much faster. **Not verified:** device timing, how the saved video looks
in the Photos app and Instagram/TikTok, audio sync by ear.

## Game labels — 2026-11-02, iPhone 17 Simulator

Real footage: the 4K `20261031_132814` recording (the leftover "Recovered" game), on the existing store.
- [x] Existing store opened on the new schema: every game, mark and clip kept; team and tournament empty
- [x] Edit screen shows Team, Opponent, Tournament, Date; saved "Eagles" / "Lakers" / "Fall Classic"
- [x] Title became "Eagles vs Lakers"; list row second line "Fall Classic · Nov 2, 2026 at 08:22"; other games unchanged
- [x] Settings → Game labels: "My team" field and "Label on exported clips" (Open and close by default)
- [x] Export sheet: "Adding label, takes longer" under Original; progress reads "Making video with label…"
- [x] Original (16:9, 9.7 s clip) frames from the saved file: label lower-left at 1 s and 8.5 s, nothing at 5 s
- [x] Vertical (9:16) frames: label at 1 s on the blurred area below the video, above the caption band; nothing at 5 s
- Screenshots and frames stayed on this Mac (scratchpad); none are in the repo
- [ ] Tournament suggestions (unit-tested; no second game with a tournament in this store yet)

## Label on Share — 2026-11-02, iPhone 17 Simulator
- [x] Share on a labelled game's 6 s clip: progress sheet ("Making video with label…", "Adding label, takes longer", Cancel)
- [x] Share sheet opened with the labelled copy (12.8 MB); label visible at 1 s in that file
- [x] Closing the share sheet removed the copy (`tmp/Exports` empty) and the progress sheet
- Fast path (label Off / no label text) and Cancel: unit-tested

## Not yet verified

- [ ] Real game **filmed on a phone camera** from the stands (landscape, with audio, 30/60 fps, rotation metadata) — the 2026-09-30 run used a screen recording
- [ ] Determinate import progress on a slow source (Files app / external drive) — Photos import is a near-instant clone
- [ ] Save Video to Photos (add-permission prompt appears only on save)
- [ ] Import from the Files app (security-scoped access)
- [ ] Insufficient-disk-space message on import
- [x] Slow motion on real phone footage (30 fps, real audio) — 2026-10-06
- [ ] Slow motion on 60 fps phone footage; whether real iPhones need the H.264 fallback
- [ ] Save to Photos on a device: vertical export time for a 13 s clip, plays correctly in Photos, audio in sync by ear
- [ ] Full-screen slow-mo preview on a device: turning to landscape while held upright, and speed change with 60 fps footage

## Faster label export — 2026-11-02, "Courtside Tests" Simulator (iPhone 17 Pro, iOS 27)

`LabelExportTimingTests` (skipped unless `TEST_RUNNER_COURTSIDE_TIMING_SOURCES` lists videos) cuts a 13 s clip from the
middle of each source through `ClipExtractor` into a temporary folder, times the exports, and removes everything it
made. Sources (read only): `20261004_105657.mp4` (4K HEVC) and `DJI_20261004_103320_13_null_video.mp4` (1080p).
One run each; seconds.

| What | 4K before | 4K after | 1080p before | 1080p after |
|---|---|---|---|---|
| No label, no frames drawn (frames copied) | 0.2 | 0.1 | 0.1 | 0.1 |
| Every frame re-made, nothing drawn, full size | — | 184.6 | — | 68.5 |
| Every frame re-made, nothing drawn, 1080p preset | — | 66.8 | — | 67.0 |
| Save to Photos, labelled (default) | 177.7 | **64.8** | 67.7 | 66.4 |
| Share, labelled (default) | 179.1 | **64.7** | 66.0 | 66.3 |
| Save to Photos, labelled, Full quality | — | 175.2 | — | 66.1 |
| Share, labelled, Full quality | — | 176.2 | — | 66.7 |
| Share right after saving (cached) | — | **0.0** | — | **0.0** |

Output: 4K labelled at 1080p is 1920×1080, 19.3 MB (Full quality 3840×2160, 25.9 MB). The time is the decode and
encode of every frame that drawing forces, not the label: drawing nothing through the same path costs the same.

Unit tests (`FasterLabelExportTests`): 1080p cap sizes (landscape, portrait upright, Vertical, never scaled up), label
present at 1080p, Full quality keeps size, cache reuse and invalidation (quality, label text, rewritten source), clip and
game deletion and launch cleanup remove cached copies, at most 4 kept, unlabelled Vertical still removed.

**Not yet checked in the Simulator UI:** the Settings picker and the elapsed time in the progress sheets (Simulator
access to "Courtside Tests" wasn't granted during this run).

## Games with more than one video — 2026-11-03, "Courtside Tests" Simulator (iPhone 17 Pro, iOS 27)

New app build on the test device. Video: the 5 s 4K clip `20261004_130244.mp4` in the device's Photos, added twice
(the same video may be added again, decision 0022).
- Import from the Games list as today: "vs Lakers", one part. The game page looked as before, with a new "Add Video"
  button under "Watch and Mark Plays".
- Add Video → Import from Photos: "Adding Video", then back to the game page with **2 Parts**: "Part 1 · 0:05" and
  "Part 2 · 0:05", each "0 marks · 26.1 MB". The totals read 0:10 and 52.3 MB, and "Watch and Mark Plays" made way for
  the Parts list.
- Tapped Part 2 and marked once (count 1). Done opened clip-making, which made 1 clip. The prompt read "Keep this
  game's videos? (26.1 MB)", only Part 2, the part with clips. Keep.
- Tapped Part 1: its marking screen started at 0 marks (Part 2's mark not shown), and one mark was placed. Clip-making
  ran with no prompt, because the game was already kept.
- Game page: "2 Clips" listed as "Part 1 · 0:00 – 0:05", then "Part 2 · 0:00 – 0:05". Both clips were clamped to their
  own 5 s part, and the kept line read "This game's videos (52.3 MB) are kept."
- Clip player: "Part 2 · 0:00 – 0:05 · 5 sec".
- Relaunched: the Games list shows one row for the game: 1 clip, 0:10, 63 MB.
- Fixed during the check: the part rows' text took the button's accent tint; it now uses plain colours.

Unit tests: `PartsMigrationTests` (old-format store → one part with everything intact; runs once; store backed up once)
and `MultiPartGameTests` (model, clamping, same tap time in two parts, trim bounds, per-part marking and Undo, resume
across parts, per-part expiry, prompt Delete, missing-file check, recovery, clip and game deletion).

Leftovers on this device from cut-off test runs earlier today: three "Recovered" 1:00 games and three small clip files
from test videos. They were left as they are.

## Clip quality — 2026-11-03, "Courtside Tests" Simulator (iPhone 17 Pro, iOS 27)

`ClipQualityTimingTests` (skipped unless `TEST_RUNNER_COURTSIDE_TIMING_SOURCES` lists videos) imports each source as a
game, taps once in the middle, makes the 13 s clip through `ClipExtractor`, trims it out by 2 s on each side, at each
setting, and removes everything it made. Sources (read only), the same as for 0021: `20261004_105657.mp4` (4K HEVC) and
`DJI_20261004_103320_13_null_video.mp4` (1080p). One run each; seconds.

| What | 4K before | 4K Full quality | 4K 1080p | 1080p before | 1080p Full quality | 1080p 1080p |
|---|---|---|---|---|---|---|
| Make 13 s clip | 307.9 | 187.8 | **67.8** | 131.3 | 78.0 | 80.9 |
| Trim to 17 s | 327.7 | 234.5 | **101.4** | 128.4 | 101.9 | 104.5 |

"Before" is the old code, measured first while the Mac was more loaded; "Full quality" is the same behavior measured in
the same run as "1080p", so those two columns are the fair comparison. Clip files: 4K at 1080p 1920×1080, 19.3 MB (Full
quality 3840×2160, 25.9 MB); 1080p sources 1920×1080 either way.

Unit tests (`ClipQualityTests`, 10): 4K landscape gives a 1920×1080 clip of the right length; 4K portrait stored
rotated and stored upright both give 1080×1920; 1920×1080, 1280×720 and 320×180 sources keep their size; Full quality
keeps 3840×2160; new clips through `ClipExtractor` follow the setting; trim follows the setting both ways; an existing
clip's file, size and window are untouched when the setting changes and clips are made again; a labelled 1080p export of
a 1080p clip keeps a 1920×1080 canvas; the default is 1080p.

Settings UI (app built and installed on "Courtside Tests"): "Clip quality" sits in its own section under Clip length, shows
"1080p (faster)" by default, and its menu offers "1080p (faster)" (checked) and "Full quality", with the footer "For new
clips and trims. 1080p is several times faster to make from 4K game videos. Clips you already have stay as they are."

## Vertical zoom — 2026-11-03, "Courtside Tests" Simulator (iPhone 17 Pro, iOS 27)

Unit and export tests (`VerticalZoomTests`, 17): zoom limits from the 1.5× cap (4K 100 %, 1920×1080 77 %, 1280×720 36 %,
320×180 none); zoom 0 matches the old layout exactly and zoom 1 fills the frame; window centered by default, 9:16, full
height at 100 %, wider than the video at 0 %; aim clamped inside the video, no up/down room within the slider's range;
portrait and square clips not framed; Share's plan stays Original; last zoom defaults to 60 % and is remembered after a
save; the sheet asks for framing only for landscape clips and shows the limit note at the cap; cached labelled copies
keyed by zoom and aim (same look reuses, a new zoom replaces). Exported frames from banded 4K and 1080p test videos at
zoom 0, 60 % and 100 % (1080p held to 77 %), plus 100 % aimed full left: every output is 1080×1920 and each column shows
the band the window math predicts; at 100 % the top and bottom rows are video, not blur; the label box stays inside the
lower-left safe area (≥ 5 % from the left, ends by 76 % across, between 20 % and 50 % up) and darkens what's under it at
every zoom; a portrait source gives the same frame with or without framing; a slow-mo render can be framed.

Export cost (`VerticalZoomTimingTests`, real footage, labelled Vertical save of a 13 s clip, seconds): 4K old layout 58.4,
zoom 0 % 64.9, 60 % 70.6, 100 % 74.1; 1080p old layout 58.0, 0 % 58.8, 60 % 70.6, 100 % (held to 77 %) 74.0. Outputs
1080×1920, 16–19 MB. See [0024](../decisions/0024-vertical-zoom.md#export-cost).

In the app (built and installed on "Courtside Tests"; game "vs Lakers", the 5 s 4K Part 1 clip): Save to Photos →
Vertical opens the full-height sheet with the still and the 9:16 window, "Zoom 60%" by default, centered. Dragged to 0 %
(window spans the width, hint "Blurred background above and below the video") and to 100 % (window full height, hint
"The sides outside the frame are cropped"), then dragged the window right. The zoom used last is the next default
(60 %, then 0 %, then 100 %). Saved at each; frames read back from the saved videos: 1080×1920 each; 60 % fills most of
the height with thin blur bands, 0 % is the old strip with the label in the blur below, 100 % fills the frame aimed
right with the label over the video. Photos add-only access was granted on this Simulator for the test (founder's
answer). Not seen in the UI: the "Zoom limited by video quality" note, since this Simulator has no landscape clip under
4K; it's covered by the session test. The three saved videos are left in that Simulator's Photos.

## Aim points — 2026-11-11, "Courtside Tests" (iPhone 17 Pro) and "Courtside Tests SE" (iPhone SE 3rd gen), iOS 27

Unit and export tests (`AimKeyframesTests`, 16): one point gives exactly the static framing and the same `ExportPlan` as a
single aim (points that never move too; Original and portrait clips ignore points); smoothstep easing hits each point on
time, halfway at half time, slow at both ends, no overshoot; holds before the first and after the last point; sampled pan
speed never exceeds 1 window width per second, close points fall short by exactly the cap, distant ones arrive exactly;
aims clamped inside the video at the export zoom, the 1.5× zoom cap unchanged; cache key includes the points; game time ↔
file time through a slow-mo segment, both ways; trim re-mapping (inside points keep their moments, nearest outside point
moves to each edge, no duplicates) and through `ClipExtractor.trim` on a stored clip; a store from before this change
opens with no points and the clip unchanged, points survive a relaunch, and deleting the clip removes them; unreadable
data means no points; the editor's session (one centered point to start, dragging it aims the whole clip, Add Point,
drafts dropped on scrub, the window between points equals the export math, 5-point limit, jump to and delete a point,
moving a mark stays between neighbors, saved in game seconds, one centered point stores nothing, slow-mo timeline);
a real 3-point export of a banded 1920×1080 video: 6 s, 1080×1920, glides left → right → middle, and each sampled frame
shows the bands the shared math predicts; a labelled export of a slow-mo render with moving aim keeps its length.
`VerticalZoomTests` (17) still pass.

Export cost (`AimKeyframesTimingTests`, real footage, 13 s clip at the 1080p default, Vertical 60 %): static and 3 points
take the same time, within ±1.6 s (4K source 81.2 / 80.9 s labelled, 75.4 / 76.2 s unlabelled; DJI 1080p 70.0 / 68.4 s
and 69.4 / 68.7 s). See [0028](../decisions/0028-aim-keyframes.md#export-cost).

In the app ("Courtside Tests SE", the 1280×720 synthetic 60 fps clip): Save to Photos → Vertical shows the clip playing
under the window with a scrub bar, one diamond at the start, "Zoom limited by video quality" at 36 %, everything on
screen at default text. Add Point at 0:06, dragged the window right (yellow while on the point); scrubbed to 0:01 and
pressed Play: the window glided right across the clip. Relaunched the app: both points were still there and the sheet
opened on the first. Largest accessibility text: video held at its minimum, play/time/point controls stacked, page
scrolls to Save Vertical; text size set back to default. Tapped the second diamond (jumped to 0:06), Delete Point: back
to one centered point, and the store shows no aim data for either clip. Not saved to Photos in the app here (the export
path is covered by the real export tests above).

## Bigger video — 2026-11-05, "Courtside Tests" (iPhone 17 Pro) and "Courtside Tests SE" (iPhone SE 3rd gen), iOS 27

"Courtside Tests SE" is a second test-only Simulator made for this check (small screen). Clips used: a landscape 4K clip
("vs Lakers", Part 1) and clips cut from the synthetic `game-30fps-portrait.mov` and `game-60fps-landscape.mov`
(imported from that Simulator's Photos). Video box measured from screenshots, as a share of the height between the
navigation bar and the bottom safe area, default text size:

| Screen | iPhone 17 Pro | iPhone SE |
|---|---|---|
| Clip | 562 / 724 pt = 78 % (portrait and landscape) | 430 / 593 pt = 72 % |
| Trim | 553 / 708 pt = 78 % | 422 / 577 pt = 73 % |

No scrolling at default text on either phone; every control on screen. Clip: info line directly under the video; Trim and
Slow Mo side by side; Save to Photos with Share and Delete tiles in one row (on both phones). Trim: filmstrip and handles
unchanged, start handle dragged (13.0 → 17.0 s, Save and Reset enabled), Reset put back 10.0 s / 3.0 s, Cancel saved
nothing; Reset on the time row on both phones. Largest accessibility text size (SE): video held at its minimum, buttons
stacked one per row with full labels, page scrolls; Trim's time row and Reset stack below the filmstrip and scroll. The
SE was set back to the default text size afterwards.

Not seen: a clip with a slow-mo version (picker shown) and the "Save Slow Mo to Photos" label in the new row; the
landscape phone orientation.

Orientation check (metadata only, no change): the sideways court in the founder's clips comes from the recording, not the
app. Three Samsung files (20261007_165457, 20261007_165634, 20261031_144105) are 3840×2160 with a 90° rotation flag, so
every player shows them as 2160×3840 portrait; 20261031_144105 is a landscape shot of the court flagged as portrait, so it
plays sideways in Photos and QuickTime too. The app applies each video's rotation flag as recorded and its clips keep the
source's flag. The DJI files (1080×1920 with a −90° flag) correctly show as 1920×1080 landscape.

