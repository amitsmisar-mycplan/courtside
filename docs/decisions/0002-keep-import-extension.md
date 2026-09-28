# 0002 — Imported videos keep their original extension

**Status:** Accepted · 2026-09-26

## Context
The spec says `Documents/Games/<uuid>.mov`, but also says accept whatever container Photos hands over (`.mov` or `.mp4`) without transcoding.

## Decision
Game videos are stored as `<uuid>.<original extension>`. The filename (with extension) is stored in `Game.videoFilename`. Clips are always `<clipUUID>.mov`.

## Consequences
File type and extension always agree, so AVFoundation never has to sniff a mislabeled container.
