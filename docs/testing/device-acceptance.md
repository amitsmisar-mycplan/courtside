# Device acceptance (steps 6–8)

Device: founder's son's iPhone (confirmed 2026-10-07).

## First install — quick checks (~20 min)
- [ ] App installs and opens; import a Camera-app video; mark, make clips, slow mo (does the log show the H.264 fallback?)
- [ ] Record Game: camera + microphone permission prompts appear once; preview is upright in both landscape directions
- [ ] Record 2 minutes on a table: tap 3 marks, Refocus, Undo one, wait 30 s for the screen to dim, tap while dim
- [ ] Hold-to-stop needs a full second; a quick tap on it doesn't stop
- [ ] Saved game has the right length; clips contain the tapped moments; clips are 60 fps (0.25× slow mo offered)
- [ ] Start recording, swipe the app away (force-quit), reopen → the recording comes back as a game with its marks
- [ ] Start recording, call the phone → recording stops, game is saved with an explanation

## Dimmed screen and Stop ([decision 0035](../decisions/0035-dim-wake-and-stop.md)) — on a tripod
- [ ] **Touch to wake:** let the screen dim (30 s without a touch), then touch it once. It wakes, and the flag count
      doesn't change
- [ ] **Wake plus quick tap:** let it dim, touch once, then again within about a second. One flag is added. Make
      clips: the clip is centered on the moment of the *first* touch
- [ ] **Recording state:** while dimmed, the red dot, the time and the flag count are readable from where you stand,
      and it doesn't look switched off
- [ ] **Setting off:** Settings → Recording → Dim screen while recording **off**. Record 2 minutes without touching:
      it never dims, and the phone never locks
- [ ] **Stop by tap:** one tap on Stop ends the recording. **Record Part 2** is the big button; tap it and record. The
      same game now has Part 1 and Part 2
- [ ] **VoiceOver on:** Stop reads "Stop recording". The dimmed screen reads "Recording, time, marks. Touch to wake."

## Recording flow fixes ([decision 0034](../decisions/0034-record-more-parts.md)) — on a tripod
- [ ] **Screen stays on:** record for 20 minutes without touching the phone. It never locks, and recording is still
      going at the end. (The app dims itself to near-black after 30 s idle, as before; that's not the lock.)
- [ ] **Wake-up touch:** after a long idle stretch, switch to another app and back, or lock with the side button and
      unlock. The first touch within a second of coming back adds no flag. Normal taps during play still flag
      instantly.
- [ ] **Record again:** Start, stop after a few seconds, then tap **Record Part 2** on the finished screen and record
      again. Done: one game with Part 1 and Part 2, and the flags from each recording are in their own part
- [ ] **From the game page:** Add Video → **Record Part N** on an imported game and on a recorded one. The new part
      shows in the same game
- [ ] **Auto-lock comes back:** after stopping and tapping Done, leave the phone on the games list. It locks at your
      usual auto-lock time. Same after the app was sent to the background mid-recording (recording stops and saves,
      as before)

## Recording lens ([decision 0026](../decisions/0026-ultra-wide-lens.md))
- [ ] First Record Game opens on 0.5× (highlighted); the preview shows about twice as much as 1×
- [ ] Tap 1× and back to 0.5×: the preview switches within a second, stays upright, and Start Recording works after
- [ ] On a tripod at the sideline, 0.5× shows the whole court; note how small players look
- [ ] Choose 1×, close the screen, force-quit, reopen Record Game → still 1×; set it back to 0.5×
- [ ] While recording, the 0.5× / 1× buttons are gone and the status box shows the lens; tapping marks still works
- [ ] Record 1 minute on each lens; save a clip of each to Photos (Original) and check its info: 1080p and 60 fps
      (if the 0.5× clip is 30 fps, note the phone model; the app falls back to 30 fps when a lens has no 1080p 60 fps)
- [ ] Refocus after switching: the picture sharpens and stays locked
- [ ] Save a 0.5× clip as Vertical with Tight (the 77 % limit on 1080p): are players big and sharp enough to share?

## Aim points ([decision 0028](../decisions/0028-aim-keyframes.md))
- [ ] Save a landscape clip as Vertical: the clip plays under the 9:16 window, one diamond at the start of the scrub bar;
      dragging aims the whole clip, as before
- [ ] Scrub to where the play moves, Add Aim Point, drag the window onto your player; add 1–2 more; Play: does the window
      glide calmly and arrive on each point? Does any glide feel too slow or fall short?
- [ ] Tap a diamond (jumps there, window yellow), drag it along the bar, Delete Aim Point
- [ ] Save Vertical with 3 points: in Photos, does the saved video move exactly like the preview? Note the save time
      next to a one-point save of the same clip
- [ ] Leave the sheet and come back, and force-quit and reopen: the points are still there
- [ ] Trim the clip shorter, then open Vertical again: points inside stay on their moments, outside ones sit at the edges
- [ ] With a slow-mo version showing: points land on the same moments, the glide through the slow part is slower
- [ ] Largest text size: video shrinks, controls stack, Save Vertical reachable by scrolling

## Clearer Slow Mo and Vertical screens
- [ ] Slow Mo: one play icon on the video and one Preview button; "your tap" under the yellow line; the line under the
      buttons says Save Slow Mo keeps it with the clip. The summary reads "Slow part: … Final video: … About …"
- [ ] Save Slow Mo → back on the clip, Slow Mo is selected and the note says to tap Save to Photos; it fades after a few
      seconds. In Photos, nothing new until you do
- [ ] Vertical: titled "Vertical Video"; outside the frame is clearly darker, "Only the bright part is kept." on the
      picture; the two numbered steps; Add Aim Point / Delete Aim Point; the zoom note names the limit
- [ ] VoiceOver: the video reads "Preview", the buttons read "Save Slow Mo", "Add Aim Point", "Delete Aim Point"; the
      slow-mo saved note is announced
- [ ] Largest text size on both screens: nothing cut off, the video keeps its size

## Framing presets ([decision 0032](../decisions/0032-framing-presets.md))
- [ ] Save a landscape clip as Vertical: Medium is selected, "Shows about 50% of the court width."
- [ ] Wide / Medium / Tight on a real play: which one keeps your player in frame without cutting the others off? Save
      one of each and compare in Photos
- [ ] With one aim point the side warning shows; add a second point and it goes away (except on Tight)
- [ ] Advanced: the slider still works; moving it deselects the choice; Save uses that zoom
- [ ] A 1080p clip (default clip quality): three choices, Tight is the 77 % limit. A clip from 720p footage: Wide and
      Medium only
- [ ] VoiceOver reads "Framing, Medium" and the readout; largest text size: nothing cut off

## Auto-follow ([decision 0033](../decisions/0033-auto-follow.md)) — at a real game, on a tripod if you can
- [ ] Film a few minutes from a tripod, make clips as usual, then Save to Photos → Vertical on 3 or 4 of them (one with
      the shot at the far basket on each side): Auto-follow is on, "Finding the action…" shows for a few seconds, then
      "Follows the action automatically." Note roughly how long it took for a 13 s clip
- [ ] Play each one in the preview: does the frame keep the shooter and the play around them? Save one and compare it in
      Photos with the same clip saved with Auto-follow off. **Write down how many were better, same, worse**
- [ ] The switch flips with a single tap (the Simulator needed a swipe; check a finger works)
- [ ] Drag the frame on one: the switch goes off and the points stay where they were, now yours to adjust
- [ ] Turn it off: the frame goes back to the middle; close and reopen Vertical: it's still off for that clip
- [ ] Wide / Medium / Tight with Auto-follow on: the frame still follows, wider or tighter
- [ ] Do the same on a clip from a recorded game and an imported one: both behave the same
- [ ] After a dozen clips, does the phone feel warm, or is the battery noticeably lower than usual?
- [ ] Delete a clip you used: nothing else changes (its saved scan goes with it)

## Find Moments ([decision 0029](../decisions/0029-find-moments.md))
- [ ] Import a full game you didn't mark (60–90 min), open it, Find Moments: the progress bar moves and the time it
      took is reasonable. **Note the minutes of video and how long it took** (the Simulator does about 0.3 s per minute;
      the phone hasn't been measured)
- [ ] Mid-scan, press Stop, then Find Moments again: it picks up near where it stopped, not from 0:00
- [ ] Mid-scan, switch to another app for a minute and come back: it carries on (or says Paused, then carries on)
- [ ] Go through the list: does each one play the right stretch? How many are plays you'd have tapped, how many are
      the other team, timeouts, or nothing? Write the count down: it decides whether the threshold needs tuning
- [ ] Accept a few, Dismiss a few, Undo one of each; Done → clips are made as usual; the clips cover the plays
- [ ] Mark a few plays by hand first, then Find Moments on another game half: nothing is suggested within 13 s of them
- [ ] A game with two parts: the button opens a menu of parts; each part has its own list
- [ ] A game recorded in the app (not imported) works the same way
- [ ] Largest text size: rows stack, Accept / Dismiss stack full width, the video stays on top
- [ ] Review layout ([0031](../decisions/0031-moments-review-layout.md)): the preview fills about half the screen;
      Accept → the row says Added, fades out, the next one plays; Undo in the bar brings it back
- [ ] Tap the preview → full screen sideways; arrows step through; Accept / Dismiss there; the shrink button returns to
      the list upright. Turn the phone sideways from the list → full screen; upright → the list
- [ ] A game filmed with the phone upright: the preview shows the whole picture (not zoomed), full screen stays upright

## Player tags ([decision 0030](../decisions/0030-player-tags.md))
- [ ] Open a clip: "Tag Player" sits beside the time line under the video; the video is the same size as before
- [ ] Tap it → Add Player… → name and number → the clip shows the name chip; tap again → pick another player or Untag
- [ ] Game page → Select → check several clips (in different parts, if the game has them) → Tag Player → pick one:
      every checked clip shows the chip
- [ ] Settings → Players → My Player → your kid; the game page shows All / My Player / Untagged / each other player;
      My Player shows only their clips, Untagged only untagged ones
- [ ] Close Courtside from the app switcher and reopen: the filter and My Player are as you left them
- [ ] Settings → a player → Delete Player: their clips stay (untagged), nothing else changes
- [ ] Largest text size: the Clip screen's tag moves under the time; rows show the tag (or "#7", or the dot); chips
      scroll sideways
- [ ] Save or share a tagged clip: the video has no player name on it

## Background clip-making ([decision 0017](../decisions/0017-background-clip-resume.md))
- [ ] Import a long game (10+ min), tap 8+ marks, Done → "Making clip 1 of 8"
- [ ] After the first clip, switch to another app for 1 minute (use it; don't just lock the phone)
- [ ] Return → the screen said "Paused" or kept going, then "Finishing your clips" and it continues by itself
- [ ] Game page: one clip per mark, no duplicates, earlier clips play; the full game video is still there
- [ ] Start again on another game, switch apps, then swipe Courtside away in the app switcher; reopen → "Finishing your
      clips" opens by itself and makes only the missing clips
- [ ] Tap Stop mid-run, close and reopen the app → nothing resumes by itself; "Make N Clips" waits on the game page
- [ ] Slow Mo on the game's first clip (tap in the first 10 s): 0.5× is offered on 30 fps footage ([0018](../decisions/0018-frame-rate-from-frame-gaps.md))

## Acceptance test (spec) — do not skip #1

- [ ] 1. Record 90 continuous minutes on a tripod in a gym-sized room
- [ ] 2. Tap at least 20 marks spread across the full duration
- [ ] 3. No interruption, no thermal shutdown, >20% battery remaining from a 100% start
- [ ] 4. All 20 clips extract and contain the tapped moments
- [ ] 5. Force-quit mid-recording → partial game is recoverable
- [ ] 6. Phone call mid-recording → graceful stop and save

Also measure: clip export time per clip on this device ([open question 2](../status/open-questions.md)).
