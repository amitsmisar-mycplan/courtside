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

## Acceptance test (spec) — do not skip #1

- [ ] 1. Record 90 continuous minutes on a tripod in a gym-sized room
- [ ] 2. Tap at least 20 marks spread across the full duration
- [ ] 3. No interruption, no thermal shutdown, >20% battery remaining from a 100% start
- [ ] 4. All 20 clips extract and contain the tapped moments
- [ ] 5. Force-quit mid-recording → partial game is recoverable
- [ ] 6. Phone call mid-recording → graceful stop and save

Also measure: clip export time per clip on this device ([open question 2](../status/open-questions.md)).
