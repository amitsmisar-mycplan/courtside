# 0029 — Find Moments: suggest highlights from a game video's sound

**Status:** Accepted · 2026-11-12 (founder's "Find the moments" spec). **Deviates from the spec's "Phase 1 has no AI"**: the
founder approved Apple's built-in, on-device sound classifier (SoundAnalysis) for this feature. It runs on the phone with
no network, no third-party code and no download, and no audio is stored. No computer vision. Adds a SwiftData model and a
field on `GamePart` (lightweight migration).

## Why
Many parents get the game video afterwards and never tapped live, or missed plays while tapping: 60–90 minutes with
nothing marked. After a made basket or a big play the crowd cheers, so the sound points at the moments worth a look.

## The classifier's labels
`SNClassifySoundRequest(classifierIdentifier: .version1)` offers **303 labels** (checked on macOS and in the iOS
Simulator; the corpus test checks again on whatever it runs on). The crowd-related ones: `cheering`, `applause`,
`clapping`, `crowd`, `yell`, `shout`, `screaming`, `children_shouting`, `booing`, `babble`, `chatter`. Game sounds:
`basketball_bounce`, `squeak`, `air_horn`. **There is no referee-whistle label**: `whistling` is a person whistling a
tune, and the rest are `train_whistle` and the like.

Used, in four groups (summed within a group, at most 1):
- **Cheering:** `cheering`
- **Applause:** `applause`, `clapping`
- **Shouting:** `yell`, `shout`, `screaming`, `children_shouting`
- **Crowd:** `crowd`

Not used: `booing` (a reaction to the other team or the referee, not a highlight), `babble`/`chatter` (the gym's constant
murmur), `air_horn` (period-end buzzers), `basketball_bounce` (present most of the game: 0.84–0.88 median confidence),
and whistles (no such label; a whistle also stops play rather than marking a highlight).

Measured on the corpus, gym crowds are quiet to the classifier: `cheering` peaks at 0.1–0.3, never near 1. A fixed
threshold can't work, so everything is measured against each video's own floor (below).

## Decision
- **Analysis component.** `Processing/MomentListener` reads **only the audio track** with `AVAssetReader` (16 kHz mono
  float, no video frames) on its own utility-priority serial queue, and feeds `SNAudioStreamAnalyzer` (3 s windows every
  1.5 s). Per second it keeps loudness (dB) and the four groups' confidence: numbers only. `Processing/MomentFinder` runs
  it for one part, one scan at a time across the app; it gets the video's URL from `StorageManager` and never builds one.
  It never exports, so `ClipExtractor` is still the only thing that does.
- **Cancellable and resumable.** Stop, closing the screen, or iOS ending background time stops the scan within one audio
  buffer. What it heard is saved every 2 minutes of audio and when stopped (`Caches/MomentScans/<part>.json`, a few
  hundred KB for a 90-minute game: loudness and four confidences per second), and the next start continues from there.
  Background time is handed back at once on expiry, as in 0017; the screen resumes when the app is back. No polling or
  busy loop: the reader blocks on its queue.
- **Peak picking** (`Processing/MomentPicker`, pure):
  - Each signal's **noise floor** is its rolling median over the surrounding 90 s, so a loud, echoey gym (or a crowd that
    fills up at half time) has a high floor. A second's **lift** is how far it stands above the floor, in units of the
    video's own spread (median absolute deviation). Spreads have a minimum so a flat or silent track doesn't make noise
    look like a moment.
  - **Score** = 0.8 × crowd-reaction lift + 0.2 × loudness lift, averaged over 3 s (a cheer lasts; a dropped ball doesn't).
    Loudness is the **fallback** (when the classifier hears nothing crowd-like, it still finds loud moments; those show as
    "Loud moment") and the **tie-breaker** (between equal scores the louder wins). On phone footage loudness barely moves
    (auto gain), so the classifier carries most of it.
  - A suggestion must be a local peak at least **3 spreads** above the video's median score and at least 1.5.
  - **At least 20 s apart** (the stronger of two close ones wins), and **none within 13 s** (the default clip window,
    10 + 3) of an existing mark in that part.
  - **At most 20 per hour** (one per started 3 minutes), the strongest kept, listed in time order.
  - The suggested time is the score's peak: the cheer just after the play. A mark there gets the usual 10 s before /
    3 s after, which covers the play.
- **Data.** `SuggestedMoment` (part, seconds in the part's video, score, status pending/accepted/dismissed, the sound
  group, the mark Accept made). `GamePart.suggestions` cascades, so deleting a game or part deletes them;
  `GamePart.momentsFoundAt` records a finished scan. Deleting a part's video (the parent, or the 7-day cleanup, or a
  missing file) removes its suggestions and saved scan too: without the video they can't become clips. Launch cleanup
  removes saved scans whose part is gone. Lightweight migration: a new model and an optional field.
- **Review.** "Find Moments" on the game page (with several parts, a menu picks the part; the button reads "Review N
  Moments" when some are waiting). The screen listens with a progress bar and Stop, then lists the suggestions in time
  order, each with its sound ("Cheering", "Applause", …). Tapping one loops its clip window from the part's video
  (`LoopingClipPlayer`, which now takes a time range). **Accept** adds an ordinary `Mark` at that time; **Dismiss** hides it
  from the count. Both move to the next pending one. Undo puts a dismissed one back, or removes an accepted one's mark
  while it has no clip yet. Closing the screen with new marks opens the usual clip-making screen, as closing marking
  does; trim, slow mo and exports work on those clips like any other. **A suggestion never becomes a clip by itself.**
- **Saving results** replaces the part's pending suggestions, keeps accepted and dismissed ones, and adds nothing within
  20 s of them, so a later second scan can't undo the parent's choices. The screen doesn't offer a second scan of a
  finished part yet (see extras).
- **Same for recorded and imported video.** Nothing branches on `Game.source`. Views render state and send intents
  (`Services/MomentReviewSession`).

## Results on the corpus
"Courtside Tests" Simulator, `FindMomentsCorpusTests`; full lists in
[testing](../testing/simulator-verification.md#find-moments).
- **Speed: about 0.3 s per minute of video** (0.27–0.32 on files over 2 minutes), so a 90-minute game takes about 30 s.
  The same code on the Mac ran at 0.12 s per minute. The iPhone hasn't been measured yet (device checklist).
- **Count:** the Nov 1 game (5 videos, 51.5 min) gave 20 suggestions; the 18 short Oct 4 clips (27 min) gave 16.
- **Against the founder's own taps:** the only taps with known times are the 5 Oct 4 test clips. Each was matched to its
  source video by its sound (correlation 0.84–1.00). Those videos are 2–3 minutes long, so the limit keeps only 1 each:
  - **1 found 8 s late** (phone 104520: tap 0:14, suggestion 0:22; its clip would start at 0:12).
  - **1 heard but not kept:** DJI 103320's tap at 1:14 was its third-strongest peak. A first version with at least 3 per
    video suggested it exactly, but gave the short clips 67 suggestions per hour, so the limit is one per 3 minutes.
  - **3 missed.** Two had only a weak crowd reaction (outranked, or within 20 s of a stronger one); one had none.
  - The Sep 10 game, the one with 20 taps, is a screen recording with no audio track, so it couldn't be used.
- **Noise:** in the short clips, the suggestions are strong applause the founder didn't tap. Whether that's noise or
  missed plays needs someone to watch them: the lists are for that. A full game with the founder's own marks is the
  test that matters (device checklist).

## Tradeoffs
- Sound, not sight: it finds what the crowd reacted to, which includes the other team's baskets and misses quiet plays.
  It's a list to skim, not a highlight reel.
- The suggestion is where the cheer peaks, a second or three after the play; with the default 10 s before, the clip
  still covers it.
- No referee-whistle signal: the classifier doesn't have one.
- A scan stopped in the last few seconds before a checkpoint re-reads up to 2 minutes of audio on resume.
