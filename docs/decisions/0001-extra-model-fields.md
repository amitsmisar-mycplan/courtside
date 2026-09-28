# 0001 — Extra model fields

**Status:** Accepted · 2026-09-26

## Context
The spec's model can't answer some questions views need without touching the file system, which the ownership rules forbid.

## Decision
| Field | Why |
|---|---|
| `Game.videoFileSize: Int64` | Storage shown in the list without statting files |
| `Game.isVideoAvailable: Bool` | False once the full video is deleted; gates marking and nudge |
| `Game.processedAt: Date?` | Starts the 7-day auto-delete clock. `recordedAt` can't be used: an imported video may be years old and would be deleted on the next launch |
| `Mark.isExtracted: Bool` | "Mark more plays" extracts only new marks; failed exports stay pending for retry |
| `Clip.fileSize: Int64` | Storage totals |

## Consequences
Sizes must be updated whenever files change (done in `ClipExtractor.nudge` and `StorageManager`).
