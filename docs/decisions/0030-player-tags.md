# 0030 — Player tags on clips

**Status:** Accepted · 2026-11-12 (founder's "Player tag on clips" spec). **Deviates from the spec's Phase 1 non-goal
"Team rosters, schedules, multi-player support"**, with the founder's explicit approval (below). Adds a SwiftData model
and an optional relationship on `Clip` (lightweight migration). Manual only: no AI, computer vision or face recognition.

## Approval
On 2026-11-12 the founder approved two exceptions to the Phase 1 non-goals:
- **Lightweight player tags** (this decision): a name, an optional jersey number and a color, tagged on clips.
- **Highlight reels** (the next planned feature; it will get its own decision record).

The approval covers **tags and reels only**. Rosters, teams, seasons, stats, computer vision and cloud/accounts remain
out of scope, except where a numbered decision record grants a specific exception (0027, 0029). CLAUDE.md's non-goals
line says the same, and the spec's non-goals carry a note pointing here; the spec itself isn't rewritten.

## Why
A parent wants to find their own kid's clips quickly, and to mark who is in a clip without leaving the app. Tagging
after the game, by hand, needs no new capture or analysis.

## Decision
- **Model.** `Player`: name, optional jersey number (digits only, up to 3, kept as text so "00" works), a color from a
  fixed palette of 8 (stored by name), creation date. **Global, not per game.** A new player gets the next unused color.
  `Clip.player` is an optional link to one player. Existing clips migrate untagged; clips in multi-part games work the
  same way. Nothing branches on `Game.source`.
- **Private.** Names and numbers stay on the phone: nothing is uploaded, and nothing is added to exported video (export
  labels, decision 0019, are unchanged).
- **Deleting.** Deleting a player untags their clips (nullify) and clears "My Player" if it was them; no clip, mark or
  file is touched. Deleting a clip, game or part leaves players alone (no cascade from clips to players).
- **Clip screen** (decision 0025). A chip on the info line under the video: "Tag Player", or the player's color dot and
  name. It opens a menu: each player (checked when current), "Add Player…" (an alert with Name and Jersey number, so
  tagging never leaves the screen), and Untag. **The video keeps every point:** the chip is drawn over a placeholder
  that reserves its width but has no height, so the info line is exactly as tall as its text. When the line is too
  narrow the chip shows "#7" (or the name when there's no number), then only the color dot. Only when the info text
  itself needs more than a line (the largest text sizes, where the video is already at its 180 pt minimum and the page
  scrolls) does the tag get its own row.
- **Several clips at once.** The game's clip list already had a selection mode (Select → check clips → Delete in the
  bottom bar, decision 0014). "Tag Player" is added to that bottom bar, with the same menu; choosing a player tags every
  selected clip and leaves selection mode. No new selection mode.
- **Filter.** Above a game's clips, once at least one player exists: All / My Player / Untagged / each other player
  (My Player isn't repeated in the list). The header reads "3 of 12 Clips" when filtered; an empty result says so with
  "Show All Clips". The choice is remembered across games and launches (`@AppStorage`). A remembered filter whose
  player was deleted, or My Player with none chosen, shows All.
- **Settings → Players.** "My Player" (None or a player), each player with its clip count (tap to edit name, number and
  color, or delete), and Add Player.
- **Rows.** A clip row shows a small chip beside its length: the color dot and name, else "#7", else (largest text) on
  its own line, down to the dot alone. VoiceOver reads "Player: Sam #7".
- **When.** Tagging happens afterwards only, from the Clip screen or the clip list, never while marking or recording.
- **Ownership.** `Player`'s static functions (`add`, `tag`, `update`, `delete`) and `ClipFilter` hold the logic; views
  call them and render state.

## Verified
"Courtside Tests" (iPhone 17 Pro) and "Courtside Tests SE", main build against this branch on the same clips: the Clip
screen's video box is **563 pt** on the 17 Pro and **431 pt** on the SE in both builds, untagged, tagged, and with a
20-character name on the SE. At the largest text size both builds hold it at 180 pt.

## Tradeoffs
- No team, roster, season or stats concepts, and one tag per clip (the clip's main player, not everyone in it).
- The filter is one setting for every game, not per game.
- A player's color is chosen from 8; with more than 8 players colors repeat.
- At the largest text sizes a long filter chip runs past the edge (the chips scroll sideways), and a row's tag can
  narrow to the color dot.
