# 0035 — Dimmed recording screen: touch to wake, recording state, optional dim; stop by tap

**Status:** Accepted · 2026-11-18. Resolves [open question 5](../status/open-questions.md) with the founder's answer:
option (b), plus backdating. Changes three points of [0011](0011-recording.md): taps on the dimmed screen no longer
mark, the dim can be switched off, and Stop is a tap instead of a 1-second hold. Builds on
[0034](0034-record-more-parts.md). No schema change.

## Why
- **The flag.** At a real game the founder touched the dimmed screen to wake it, and the touch marked a moment
  (0011: "taps still mark").
- **The dim looked like the screen turning off.**
- **Stopping.** Stopping needed a deliberate hold. Now that Record Part N continues the same game (0034), an accidental
  stop costs a few seconds of footage, not the game.

## Decision
- **Touch to wake.** On the self-dimmed screen the first touch only wakes it: brightness comes back, controls show, and
  there is no mark, haptic or flash.
  - **Within 3 seconds** (`RecordingSession.backdateWindow`): a second touch places a mark **at the time of the first
    touch**, so a quick deliberate double tap doesn't lose the moment.
  - **Later or never:** with no second touch nothing is marked; after 3 s the next touch is an ordinary tap at its own
    time.
  - **Same rules as any mark:** the backdated mark goes through the 2 s debounce and can be undone.
  - **Awake screen:** unchanged. Touch-down marks, with the debounce, haptic, flash and Undo.
  - **1 s guard:** the guard after returning to the app or opening the screen (0034's fix) still applies.
- **The dimmed screen shows it's recording.**
  - **What's kept:** the battery dim itself (brightness 0.05 with a 92 % black cover).
  - **What it shows:** a red dot, the elapsed time (48 pt, bold) and the mark count, in full white, plus "Recording ·
    touch to wake".
  - **No buttons**, so nothing on the dark screen can stop or undo.
  - **VoiceOver** reads it as one line: "Recording, 12:34, 3 marks. Touch to wake."
- **Settings → Recording → "Dim screen while recording".**
  - **Default:** on (`RecordingSettings`, stored in UserDefaults).
  - **Off:** the screen never dims, so every touch marks as it does on an awake screen.
  - **Auto-lock:** held off by `ScreenAwake` while recording either way.
- **Stop by tap.**
  - **The button:** the Stop button keeps its place and size (68 pt) and stops on a tap.
  - **VoiceOver:** "Stop recording". The hint is "Stops and saves. You can record the next part right after."
  - **Why one tap is safe enough:** the button is hidden while the screen is dimmed, and the first touch on the dimmed
    screen only wakes it. So a stray touch on a dark screen can't stop recording; on an awake screen, Stop must be hit
    directly.
- **Finished screen:** **Record Part N** is the primary (filled, red) button, before Make Clips and Done.

## Tradeoffs
- **Marking from a dark screen** takes two touches. A single touch, which used to mark, now only wakes.
- **The second touch reaches back** up to 3 s: a deliberate tap 2 s after waking for a *new* play marks the earlier
  moment. A clip covers 10 s before the mark, so both moments are usually in it.
- **An accidental Stop** on an awake screen loses the seconds until Record Part N is tapped, and leaves two parts.
