# 0004 — Full-video retention vs. nudge and re-marking

**Status:** Accepted · 2026-09-26, revised 2026-09-28 (Keep = forever, founder decision)

## Context
Nudge trim re-exports from the full game video, and "add more marks" plays it. The spec also deletes that video
(user choice, or 7 days after processing).

## Decision
- After processing, the parent is asked "Keep the full game video?".
  - **Keep** sets `Game.keepsVideo`; the video is **never** auto-deleted. The prompt isn't shown again for that game.
  - **Delete** removes it now.
  - **Unanswered** (app closed before choosing): the launch-time cleanup deletes it 7 days after `processedAt`.
- A kept video can be deleted later from the game page ("Delete…" next to the video status).
- When the full video is gone, nudge and "Mark More Plays" are disabled, with an explanation on screen.
- For imported games, the prompt notes the original is still in Photos (display-only use of `source`).

## Consequences
Kept videos use storage until the parent deletes them or the game; the games list shows per-game and total storage.
