# 0019 — Game labels (team, tournament) and a burned-in label on exported clips

**Status:** Accepted · 2026-11-02 (founder's "game labels" spec). Extends [0013](0013-game-library.md) (game details)
and [0016](0016-export-to-photos.md) (export pipeline).

## Part 1: labels on the game
- **Schema (`Game`)**: two optional fields, `team: String?` and `tournament: String?`. Both start nil, so SwiftData's
  lightweight migration adds them with nothing rewritten. Tested against a store built with the old schema.
- **"My team" setting** (Settings → Game labels, UserDefaults). New games (import, recording, recovered recordings) start
  with it as their team; it can be changed per game. Nothing is ever asked before recording or importing.
- **Tournament is free text with suggestions.** While the Tournament field is focused, the editor lists names used on
  other games that contain what's typed (case-insensitive), most recent game first, each name once, at most five. No
  Tournament model.
- **Title rule** (extends 0013): "Team vs Opponent" when both are set → "vs Opponent" → the name → "Untitled game". A team
  with no opponent keeps today's fallbacks. The row's second line is "Tournament · date", or the date alone.
- **Edit screen**: Team, Opponent, Tournament and Date in the first section.

## Part 2: label on exported clips
- **Text**: line 1 "Team vs Opponent" ("vs Opponent" or "Team" when one is missing); line 2 "Tournament · Nov 1, 2026"
  (either part alone). A line with both parts empty is dropped. Never the score, notes, the game's name or player names.
  The date is always formatted "MMM d, yyyy" in English, the same on every phone.
- **No empty label**: a label needs at least one of team, opponent or tournament. The date alone (every game has one)
  isn't a label, so a game with none of the three exports without one, whatever the setting.
- **Fitting**: the box, padding included, is at most 70 % of the frame width. Names are shortened with "…": on line 1 the
  longer name gives way first; on line 2 only the tournament shrinks, never the date.
- **Style**: white text (semibold, then regular at 85 %) on a black box at 55 % opacity with rounded corners. Sizes scale
  with the frame's short side (title 3.6 %, detail 2.8 %).
  - **16:9 and other wide frames**: lower left, inside a 5 % margin.
  - **9:16**: 6 % from the left and 22 % up from the bottom, above the band where Instagram and TikTok put captions and the
    account name. The box ends by 76 % across, short of their buttons on the right.
- **Timing**: 2.5 s at the open and 2.5 s at the close, each fading in and out over 0.3 s; never in the middle. Under 7 s,
  the open only, for a third of the clip. The two windows are always at least 2 s apart, so they never meet.
- **Setting** "Label on exported clips": Off / Open and close (default).
- **Placed by final length**: the windows come from the exported file's own duration, so a trimmed clip or a slow-mo
  render gets its closing label at its real end.

## One pipeline, one overlay mechanism
- The label is a frame step in the existing `ExportPlan` → `ExportComposer` → `ClipExtractor.exportForSharing` path.
  No new export path; same preset (HEVC Highest Quality), re-encoded, serial.
- `ExportFrameStep` gains `prepared(canvas:duration:)`, called once before the first frame. `LabelStep` uses it to draw
  its box once (Core Text) and time itself by the final length, returning a `TimedOverlay`: an image plus time windows
  with fades. **The watermark (feature 7) reuses `TimedOverlay`** with one window covering the whole clip. The end card
  stays a timeline step (it changes length), but can draw its text with the same renderer.

## Original: fast path vs. label
Original used to save the clip file itself (about a second, no re-encode). With a label it can't: it goes through the
composition path like Vertical. With the setting Off or no label text it keeps the fast path. The export sheet says which
under Original: "Adding label, takes longer" or "Fast, no label", and the progress title reads "…with label".

## Not changed
- **Share** still hands over the clip file as it is, with no label.
- Score, notes and the game name stay app-only.

## Verified
- Unit tests (`GameLabelTests`): text with every field and each missing combination; blank fields; no label from the date
  alone; score and notes never included; Off and empty give no label; very long names fit with "…" and the date kept
  whole; the box stays within 70 %; windows for 13 s, 7 s, 6.9 s and 3 s, never overlapping at any length from 0.1 to
  60 s; fades; tournament suggestions; titles and the row subtitle.
- Export tests (`LabelExportTests`, real exports, frames sampled inside the label box against the plain video):
  - 13 s: label at 1 s and 12 s, none at 6 s.
  - 3 s: open only.
  - 9:16: label at the open and close, and the bottom caption band untouched.
  - A 9 s file gets its closing label at its own end.
- Export session: Original with a label is rendered; with the setting Off or no label text, the clip is saved as it is.
- Migration (`GameLabelMigrationTests`): a store from the old schema opens with empty team and tournament, and its
  marks, clips and score kept.
