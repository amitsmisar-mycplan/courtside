# Courtside — project context for Claude Code

> **This file is the source of truth for this repository.** The root `CLAUDE.md` describes a different
> product (Kash, a Next.js finance PWA) and does not apply here — ignore its stack, rules, and
> "never create native iOS code" instruction. The owner has asked that it be left untouched.

## What this is

Native iOS app for a parent whose kid plays basketball. A game video goes in (imported now, recorded live later).
The parent taps when something good happens. Individual clips come out. Everything on-device: no AI, backend,
accounts, or upload in Phase 1.

Full spec: [`docs/spec/phase-1-technical-spec.md`](../docs/spec/phase-1-technical-spec.md). Read it before any
non-trivial change.

## Where things are

- `Courtside/Courtside.xcodeproj` — single app target + unit-test target, folder-synced groups (new files are picked up automatically)
- `Courtside/Courtside/` — `App/`, `Models/`, `Import/`, `Processing/`, `Playback/`, `Views/`
- `Courtside/CourtsideTests/` — clip-window math, storage, real export tests
- `docs/status/progress.md` — current build step; `docs/status/open-questions.md` — pending founder decisions
- `docs/decisions/` — numbered records of every deviation from the spec. **Add one whenever you deviate.**

## Build and test

```
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=iPhone 17' test
```

All tests must pass and the build must have zero warnings before committing.

## Hard rules

- **Build order is gated.** Steps 1–5 are done. **Do not start step 6 (recording) until the founder confirms a device is available.**
- iOS 17 minimum, Swift 5 language mode, SwiftUI + SwiftData, iPhone only, **no third-party dependencies**.
- **Never store absolute file URLs.** Models store relative filenames; `StorageManager` is the only thing that builds URLs.
- **Ownership:** `ClipExtractor` is the only thing that runs an export; `CaptureSessionController` (step 6) the only thing that touches `AVCaptureSession`.
  Views render state and send intents — no AVFoundation logic, no file system, no queries beyond `@Query`
  (player wrappers live in `Playback/`, see decision 0003).
- **No logic branches on `Game.source`** past game creation. If you need to, stop and raise it.
- **Copy, never reference,** picked videos. Balance security-scoped access.
- Clip export: `AVAssetExportPresetHEVCHighestQuality`, never passthrough; serial, never parallel.
- **Losing footage is the one unforgivable bug.** Never delete a complete game video that has no `Game` record — orphans are for step 7 recovery.
- Non-goals (computer vision, stats, cloud/accounts, reels, rosters, Android/iPad/Watch) are out of scope.

## Working style

- Read files before changing them; match the surrounding code's style and comment density.
- Verify behavior in the Simulator for UI changes, not just tests.
- Update `docs/status/progress.md` and `docs/testing/` when a step or verification changes.
- Work on a branch; `main` changes only with the founder's go-ahead.
