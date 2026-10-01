# Courtside — Feature Spec: Slow Motion

Addendum to `docs/phase1-technical-spec.md`. Build this after 1.5 (playback, trim,
share) is complete. Fully verifiable in the Simulator.

## What this is

A clip already exists. The parent taps "Slow Mo" and gets a version where the moment
around the mark plays in slow motion, with normal speed on either side. It's for sharing
— the thing that makes a clip feel finished rather than raw.

**This is a rendering feature. No AI, no detection, no new analysis.** The app already
knows where the interesting moment is: it's the mark.

## Scope

- Slow motion applied to a segment within an existing clip
- Two speeds: 0.5x and 0.25x (subject to the frame-rate rule below)
- Adjustable slow segment, defaulting around the mark
- Rendered to a separate file, original clip untouched
- Shareable and deletable independently

Not in scope: ramping curves beyond a simple three-part structure, frame interpolation,
music, text overlays, slow motion during live capture.

## The frame rate problem — read before designing

Slow motion works by stretching existing frames over more time. It does not create
frames. So the source frame rate hard-caps how far you can slow down before it looks
like a stutter rather than slow motion.

Read `nominalFrameRate` from the video track and cap accordingly:

| Source | Max slow factor | Offer |
|---|---|---|
| 60fps or higher | 0.25x | 0.5x and 0.25x |
| 30fps | 0.5x | 0.5x only |
| under 30fps | none | disable, explain why |

This matters because the two paths differ. Live capture is 1080p60 per spec, so
recorded games get the good version. **Imported video from other parents' phones is
frequently 30fps**, and some is 24fps. Detect and degrade; never silently produce
stuttering output.

Surface the source frame rate somewhere in the UI when it limits the options, with a
plain explanation — "this video was recorded at 30fps, so 0.25x isn't available."

Do not attempt frame interpolation. Optical-flow interpolation is a real technique but
it's a research-grade problem on sports footage with fast limb motion, and it produces
smeared artifacts exactly on the fast-moving thing you care about.

## Structure of the output

Three segments, not uniform slowdown:

```
[ normal speed ][ slow ][ normal speed ]
                   ^
                 mark
```

Defaults, relative to the clip's own timeline (mark sits at 10s in the standard 13s clip):

- Slow segment: `[mark - 2.0s, mark + 1.5s]` → 3.5 seconds of source
- At 0.5x that becomes 7 seconds of output; at 0.25x, 14 seconds
- Everything before and after plays at 1x

Clamp the slow segment to the clip bounds. If the clip is shorter than the slow segment,
slow the whole thing.

Rationale for a windowed slow segment rather than the whole clip: the lead-up gives
context and the slow part gives impact. A uniformly slow 13-second clip is boring and
three times too long to share.

## Implementation

`AVMutableComposition` with `scaleTimeRange(_:toDuration:)`.

Outline:

1. Load the clip as `AVURLAsset`
2. Create a composition with one video track and one audio track
3. Insert the full clip's time range into both
4. Call `scaleTimeRange` on the **video** track for the slow segment only, with
   `toDuration` = segment duration ÷ speed factor
5. Handle audio separately (below)
6. Export with `AVAssetExportSession`, `AVAssetExportPresetHEVCHighestQuality`

**Preserve the preferred transform.** Copy `preferredTransform` from the source video
track to the composition track, or portrait and rotated footage exports sideways. This
is the most common way this feature ships broken.

### Audio

Scaled audio sounds bad — pitch-shifted and slurred. Do not scale it.

Ship this: keep audio at normal speed for the two normal segments, silent during the
slow segment. Concretely, insert the pre-segment audio, leave a gap matching the
stretched slow duration, then insert the post-segment audio at the correct offset.

If gap handling turns out fiddly, the acceptable fallback for v1 is muting the whole
slow-mo clip. Tell me if you go that route rather than deciding silently — gym crowd
noise is a meaningful part of why these clips feel real.

### Where the file goes

- `Documents/Clips/<clipUUID>-slowmo-<speed>.mov`
- Same backup exclusion rules as everything else
- `StorageManager` owns the path, as always

### Data model

Add to `Clip`:

```swift
var slowMoFilename: String?      // nil = not rendered
var slowMoSpeed: Double?         // 0.5 or 0.25
var slowMoStartSeconds: Double?  // within the clip
var slowMoEndSeconds: Double?
```

Re-rendering with different settings replaces the file and updates the fields. Deleting
a clip cascades to its slow-mo file.

This is a schema change to an existing model — per CLAUDE.md, confirm with me before
applying it.

## UI

In the clip player, a "Slow Mo" button.

Opens a sheet:
- Speed picker (0.5x / 0.25x, with unavailable options disabled and explained)
- A scrubber for the slow segment, pre-set to the default window, draggable
- Preview button — plays the composition **without exporting**, using
  `AVPlayerItem(asset: composition)`. This is important: export takes seconds, preview is
  instant, and the parent will fiddle with the window several times before settling.
- Render button

After rendering, the slow-mo version appears in the clip player as a toggle between
Original and Slow Mo. Share sheet acts on whichever is selected.

Show a size estimate. A 0.25x render of a 13-second clip is roughly 24 seconds of video.

## Gotchas

1. **`preferredTransform` must be copied** or output is rotated.
2. `scaleTimeRange` operates on the composition track's own timeline. After an earlier
   scale, subsequent time ranges shift. Apply one scale operation only — don't try to
   compose multiple scaled ranges.
3. Do not use passthrough export; the composition must be re-encoded.
4. `AVPlayerItem` built from a composition is fine for preview but holds the asset — tear
   it down when the sheet dismisses, or memory grows as the user experiments.
5. Exporting from a composition can fail with `AVError.compositionTrackSegmentsNotContiguous`
   if audio gaps are built wrong. Handle it, and surface a real message.
6. Check `nominalFrameRate` on the **video** track specifically, not the asset.

## Unit tests

Pure logic only:
- Slow segment clamping against clip bounds
- Output duration math for each speed
- Frame-rate-to-available-speeds mapping (60 → both, 30 → 0.5x only, 24 → none)
- Filename generation

## Verification in the Simulator

1. Import a 60fps game video, make a clip, render 0.25x — confirm smooth, correct
   segment, right orientation, audio normal-silent-normal
2. Import a 30fps video — confirm 0.25x is disabled with an explanation, 0.5x works
3. Import a 24fps video — confirm slow-mo is disabled with an explanation
4. Drag the slow segment to the clip's start and end — confirm clamping holds
5. Render, delete the clip, confirm both files are gone
6. Re-render the same clip at a different speed — confirm the old file is replaced, not
   orphaned
7. Preview repeatedly without rendering — confirm memory doesn't climb

Test with portrait-shot footage at least once. Parents film vertically more often than
they should.
