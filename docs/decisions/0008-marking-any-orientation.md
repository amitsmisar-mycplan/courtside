# 0008 — Playback marking works in either orientation

**Status:** Accepted · 2026-10-01 (founder chose option b, open question 3)

## Context
The spec landscape-locks the playback-marking screen. Portrait videos (common from parents) were shrunk to a thin strip.

## Decision
Playback marking allows portrait and both landscape orientations; the parent turns the phone to suit the video.
The control strip adapts: one row in landscape (as before), two rows in portrait (scrub bar on its own row).
The rest of the app stays portrait. **Recording (step 6) stays landscape-locked** as the spec says — this decision
covers playback marking only.

## Verified
Simulator: portrait 1080×2316 video fills the screen in portrait; landscape layout unchanged; taps mark in both.
Not verified: live rotation mid-playback (couldn't rotate the Simulator from the session) — check on a device.
