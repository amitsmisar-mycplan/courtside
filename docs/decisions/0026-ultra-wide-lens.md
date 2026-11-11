# 0026 — Record with the ultra-wide lens

**Status:** Accepted · 2026-11-11 (founder's "ultra-wide recording lens" spec). Departs from the technical spec's capture
settings ("back wide camera at zoom 1.0"); every other capture setting is unchanged.

## Why
On a tripod the main 1× camera sees about half a basketball court. The 0.5× ultra-wide lens has about twice the
horizontal field of view, enough for the whole court.

## Decision
- **Two lenses:** ultra-wide (0.5×, `.builtInUltraWideCamera`) and main (1×, `.builtInWideAngleCamera`), each at its
  own zoom factor 1.0. No digital zoom, no virtual multi-camera device: a lens switch is an explicit choice.
- **Default:** ultra-wide on phones that have it, the main camera otherwise. The parent's last choice is remembered
  across launches in UserDefaults (`recordingLens`); no SwiftData change. A remembered lens the phone lacks falls back
  to the other one, without overwriting the remembered choice (`LensSettings.choose`).
- **Choice on the record screen:** 0.5× / 1× buttons above Start Recording, only on phones with both lenses. They can
  change the lens only while the screen is ready; once recording starts they're gone and the lens shows in the status
  box ("locked while recording"). Start Recording waits while a switch is in progress.
- **Ownership:** `CaptureSessionController` stays the only thing that touches `AVCaptureSession`. A switch swaps the
  camera input inside one configuration block, refuses while the movie output is recording, and puts the old input
  back if the new one fails. `RecordingSession` holds the lens state and saves the choice; the view only shows state
  and sends intents (`CameraLens` has no AVFoundation).
- **Unchanged capture settings, applied to whichever lens is active:** 1920×1080, 60 fps if the lens offers a 1080p
  60 fps format, else 1080p 30 fps (logged as "Recording format 1920x1080 @ N fps on the 0.5× lens"); HEVC; audio on;
  stabilization off; focus and exposure lock after the 3 s settle (restarted after a switch, and a lock scheduled for
  the old lens is skipped); idle timer off; interruption handling; no maximum duration. Geometric distortion correction
  is left at the system default.

## Tradeoffs
- **Players are about half the size in the frame.** With twice the field of view, a player covers about half as many
  pixels across. Clips play smaller, and details (jersey numbers, the ball) are softer.
- **Vertical zoom ([0024](0024-vertical-zoom.md)) can't make up for it on recorded games.** The recorder writes 1080p,
  so every clip from a recorded game is 1080p and stops at the 77 % cap (1.5× upscale), whatever the Clip quality
  setting. A player's height in the Vertical frame, relative to its height in a 1080p main-camera source P:

  | Zoom | Main camera (1×) | Ultra-wide (0.5×) |
  |---|---|---|
  | 0 % (fit width) | 0.56 P | 0.28 P |
  | 77 % (the cap) | 1.5 P | 0.75 P |

  At the cap, an ultra-wide clip shows players about as large as a main-camera clip at roughly 15 % zoom, and the
  window spans about 38 % of the frame's width (around three-quarters of what the main camera sees). The cap is the
  same, but it now binds on every recorded clip the parent zooms. The parent can still choose 1× for closer games.
- **Frame rate on the ultra-wide** depends on the phone. Recent iPhones are expected to offer 1080p 60 fps on the ultra-wide;
  if a phone doesn't, recording falls back to 30 fps (slow mo then offers 0.5×, not 0.25×). Not verified
  without a device; see the lens check in [device acceptance](../testing/device-acceptance.md).
- **Edges:** distortion correction is on by default where supported, which slightly crops the ultra-wide; the
  sidelines at the far corners may still bend a little.
