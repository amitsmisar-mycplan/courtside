# 0005 — Partial files and orphaned videos

**Status:** Accepted · 2026-09-26

## Decision
- All in-progress writes (import copies, clip exports) go to `<name>.partial.<ext>` and are renamed on success.
- On launch, `StorageManager.performLaunchCleanup` deletes any `*.partial.*` files in `Games/` and `Clips/`.
- Complete game videos with no `Game` record are **never** deleted. Step 7 turns them into recoverable games.
- If a game's video file is missing on launch, the game is marked `isVideoAvailable = false` rather than deleted.

## Consequences
A crash mid-import leaves nothing behind. A crash mid-recording (step 6+) will leave a complete file for recovery.
