# Simulator verification (steps 1–5)

## Automated tests — 20/20 passing

```
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `ClipWindowTests` — all five spec cases (t=2s clamp, 1s before end, exactly 0, exactly duration, zero-length game) plus nudge and settings clamping
- `StorageManagerTests` — relative filenames only, backup exclusion on `Games/` and `Clips/`
- `ClipExportTests` — real HEVC export of a generated, rotated video: duration within 0.1 s, rotation preserved (gotcha #7), first frame within one frame of target

## Manual walkthrough — 2026-09-26, iPhone 17 Simulator, iOS 27

Test material: 5-minute generated video with a timecode on every frame.

| Check | Result |
|---|---|
| Import from Photos, copied into `Documents/Games/` | ✅ |
| `Games/` has backup-exclude attribute | ✅ |
| Duration correct (5:00); label uses embedded creation date | ✅ |
| Marking screen landscape-locked, playing | ✅ |
| Marks at 1×, 1.5×, 2×; ticks on scrub bar | ✅ |
| Debounce: two quick taps → one mark | ✅ |
| Undo removes the last mark | ✅ |
| Control strip taps don't place marks | ✅ |
| 5 clips extracted, windows = [mark − 10 s, mark + 3 s] | ✅ |
| Frame 10 s into each clip shows the tapped timecode | ✅ (all 5, incl. 2× marks) |
| Keep/Delete prompt with size | ✅ |
| Detail grid with midpoint thumbnails | ✅ |
| Nudge end +1 s: same file replaced, thumbnail regenerated | ✅ |
| Share sheet opens | ✅ |
| Delete game removes video, clips, thumbnails, rows | ✅ |

Fixed during the walkthrough: game page briefly laid out in landscape after Done; redundant Cancel on the Keep/Delete alert.

## Not yet verified

- [ ] Real 60–90 minute game from the stands (import progress on a multi-GB file, 20 marks at 1× and 2×)
- [ ] Save Video to Photos (add-permission prompt appears only on save)
- [ ] Import from the Files app (security-scoped access)
- [ ] Insufficient-disk-space message on import
