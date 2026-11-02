# 0018 — Slow-mo frame rate measured from the typical gap between frames

**Status:** Accepted · 2026-11-02. Answers [open question 4](../status/open-questions.md) with a fix and revises the
"Frame-rate cutoffs" section of [0007](0007-slow-motion.md). Bug 2 in [corpus-nov-1](../testing/corpus-nov-1.md#bugs-found).

## Problem
Slow-mo speeds came from the clip track's `nominalFrameRate`, which is an average: frames ÷ duration. Every phone
recording in the Nov 1 corpus pauses 0.20–0.21 s after its first frame. A clip cut from 0:00 carries that pause, so
30 fps footage read 28.85–29.60 fps on a 10 s clip and 27.25 fps on a 4 s clip, under the 0.5× cutoff of 28. Slow mo was
switched off with a wrong "27 fps" message. Very short clips (open question 4: 1.5 s reading 26 fps) under-read the same
way.

## Decision
- `SlowMoComposer.videoFrameRate` reads the clip's frame timestamps (no decoding, at most 900 frames) and
  `SlowMotion.frameRate(presentationTimes:)` returns 1 ÷ the **median** gap between frames. One long pause can't move
  the median, so a 30 fps clip reads 30 however it starts or however short it is.
- The cutoffs are unchanged: 0.5× needs ≥ 28 fps, 0.25× needs ≥ 55 fps. 30 fps footage still never gets 0.25×.
  Genuinely slower footage (24, 25, 20 fps) still reads its true rate, with or without a start-up pause, and gets no
  slow mo, as before.
- If the timestamps can't be read (or there are fewer than three frames), it falls back to `nominalFrameRate`.

## Why the median
Reading from the second frame fixes only the start-up pause. The median also ignores an odd dropped or duplicated frame
anywhere in the clip, and for steady footage it equals the true rate exactly.

## Verified
- Unit tests (`SlowMoFrameRateTests`): the five Nov 1 first clips (old readings 28.85–29.60 fps) and the trial's 27.25 fps
  4 s clip all read their source rate (29.95–29.99) and offer 0.5× only; a 1.5 s 30 fps clip reads 30; 23.976/24/25/20 fps
  read true and offer nothing; 60 fps with a pause offers both speeds.
- Real export: a 30 fps source with a 0.4 s pause after frame 1, clipped from 0:00, has `nominalFrameRate` under 28 and
  now reads 30.0.
- Real footage (Simulator): a clip cut from 0:00 of `20261031_132814` reads 29.50 fps the old way and 30.01 the new way.
