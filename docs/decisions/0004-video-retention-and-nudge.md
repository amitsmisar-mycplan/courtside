# 0004 — Full-video retention vs. nudge and re-marking

**Status:** Accepted — Keep semantics still open (see [open questions](../status/open-questions.md))

## Context
Nudge trim re-exports from the full game video, and "add more marks" plays it. The spec also deletes that video (user choice, or 7 days after processing).

## Decision
- When the full video is gone, nudge and "Mark More Plays" are disabled, with an explanation on screen.
- The Keep/Delete prompt warns about this.
- "Keep" currently means keep until `processedAt + 7 days`; the launch-time cleanup deletes it after that.
- For imported games, the prompt notes the original is still in Photos (display-only use of `source`).

## Consequences
After 7 days, clips are fixed. If the founder wants Keep to mean forever, change `Game.videoExpiresAt` and the prompt text.
