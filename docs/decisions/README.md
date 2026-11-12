# Decisions

One file per decision that deviates from or extends the spec. Add new ones with the next number.

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-extra-model-fields.md) | Extra SwiftData fields beyond the spec's model | Accepted |
| [0002](0002-keep-import-extension.md) | Imported videos keep their original extension | Accepted |
| [0003](0003-playback-folder.md) | `Playback/` folder for AVPlayer wrappers | Accepted |
| [0004](0004-video-retention-and-nudge.md) | Deleting the full video disables nudge and re-marking | Accepted — revised: Keep = forever |
| [0005](0005-partial-files-and-orphans.md) | `.partial` files swept on launch; orphans kept for step 7 | Accepted |
| [0006](0006-marking-ux-details.md) | Touch-down marking, wall-clock debounce, auto-processing | Accepted |
| [0007](0007-slow-motion.md) | Slow motion: two extra `Clip` fields, frame-rate cutoffs, lifecycle | Accepted |
| [0008](0008-marking-any-orientation.md) | Playback marking works in either orientation | Accepted |
| [0009](0009-slowmo-h264-fallback.md) | Slow-mo render falls back to H.264 if HEVC fails | Accepted |
| [0010](0010-bundle-id.md) | Bundle ID `com.awave.courtside` | Accepted |
| [0011](0011-recording.md) | Recording (step 6) + footage-safety parts of step 7 | Accepted — device test pending |
| [0012](0012-slowmo-fullscreen-preview.md) | Slow-mo preview full screen, turned to match the video (departs from 0008) | Accepted |
| [0013](0013-game-library.md) | Game library: opponent, score, notes; name and opponent both kept | Accepted |
| [0014](0014-undo-stack-and-clip-delete.md) | Repeatable Undo by mark ID; delete clips by swipe or selection | Accepted |
| [0015](0015-clip-trim.md) | Trim a clip: 30 s before / 15 s after the tap, re-cut through ClipExtractor; replaces nudge | Accepted |
| [0016](0016-export-to-photos.md) | Save to Photos: Original or Vertical 9:16 with blurred background; same preset | Accepted |
| [0017](0017-background-clip-resume.md) | Clip-making stops cleanly when background time runs out and finishes the missing clips later | Accepted — device test pending |
| [0018](0018-frame-rate-from-frame-gaps.md) | Slow-mo frame rate from the median gap between frames (answers open question 4) | Accepted |
| [0019](0019-game-labels.md) | Team and tournament on games; burned-in label at the open and close of exported clips | Accepted |
| [0020](0020-label-on-share.md) | Share carries the game label (labelled Original rendered first); fast path without one | Accepted |
| [0021](0021-faster-label-export.md) | Labelled exports at 1080p by default (HEVC 1080p preset), cached while the app runs | Accepted |
| [0022](0022-multi-part-games.md) | Games with more than one video (parts): model, migration, per-part retention | Accepted |
| [0023](0023-clip-quality.md) | Clips and trims at 1080p by default ("Clip quality"); Full quality keeps the old behavior | Accepted |
| [0024](0024-vertical-zoom.md) | Zoom and aim for Vertical exports of landscape clips, capped at 1.5× upscale | Accepted |
| [0025](0025-bigger-video.md) | Video takes most of the Clip and Trim screens; Save, Share, Delete share a row when they fit | Accepted |
| [0026](0026-ultra-wide-lens.md) | Record with the 0.5× ultra-wide lens by default; 0.5× / 1× choice before recording, remembered | Accepted |
| [0027](0027-tap-to-follow-spike.md) | Tap-to-follow tracking spike: debug-only screen, Apple Vision tracker, local results log | Experiment |
| [0028](0028-aim-keyframes.md) | Aim points for Vertical exports: the window glides between up to 5 moments, eased and speed-capped | Accepted |
| [0029](0029-find-moments.md) | Find Moments: suggest highlights from a part's sound (on-device sound classifier, approved deviation from "no AI") | Accepted |
| [0030](0030-player-tags.md) | Player tags on clips: name, number, color; tag, filter, My Player (approved exception to the roster non-goal; covers tags and reels) | Accepted |
