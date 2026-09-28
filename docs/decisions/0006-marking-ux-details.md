# 0006 — Marking UX details

**Status:** Accepted · 2026-09-26

- **Marks are placed on touch-down**, not touch-up, so the offset is as close to the moment as possible.
- **Debounce is 2 s of wall-clock time** (`CACurrentMediaTime`), so at 2× playback it's 4 s of video.
- **Add Game is one menu:** Import from Photos, Import from Files, Record Game (disabled, "Coming soon").
- **After Done in playback marking**, processing starts automatically if there are new marks.
- The screen stays awake during playback marking and processing.
