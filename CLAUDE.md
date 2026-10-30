# Courtside — project context for Claude Code

## What this is

Native iOS app for a parent whose kid plays basketball. A game video goes in (imported now, recorded live later).
The parent taps when something good happens. Individual clips come out. Everything on-device: no AI, backend,
accounts, or upload in Phase 1.

Full spec: [`docs/spec/phase-1-technical-spec.md`](docs/spec/phase-1-technical-spec.md). Read it before any
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

- **Build order.** Steps 1–5 are done. A device is confirmed (2026-10-07, founder's son's iPhone), so step 6 (recording) is unblocked — first install and verify steps 1–5 on the device, then build step 6.
- Bundle ID is `com.awave.courtside` (decision 0010). The Simulator app ID changed with it, so the old `com.example.courtside` Simulator data is a separate app.
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

## Feature rules

- SwiftData schema changes need a lightweight migration. Existing user data must survive.
- Deleting a clip, game, or source video removes only the files it owned, via `StorageManager`. No orphans. Anything that deletes a source video needs explicit user confirmation and a decision record.
- Trims, exports, slow-motion, reels, and overlays extend `ClipExtractor` (or a composition builder it calls). No second export path.
- Do only the requested feature. List worthwhile extras at the end of your report instead of building them.
- End each task with: what changed, what to test on a real device, known limits. Update `docs/status/progress.md`.
- The app stays private (founder-only TestFlight) until the founder says otherwise.

## Working style

- Read files before changing them; match the surrounding code's style and comment density.
- Verify behavior in the Simulator for UI changes, not just tests.
- Update `docs/status/progress.md` and `docs/testing/` when a step or verification changes.
- Work on a branch; `main` changes only with the founder's go-ahead.


Create a branch with `git checkout -b chore/ship-rule --no-track origin/main`. Add the section below to CLAUDE.md, and create scripts/repo-health.sh. The script should run `git fetch`, then print: the current branch, `git status -s`, and for every local branch the number of commits not in origin/main and its upstream. Commit both, then run `git push -u origin chore/ship-rule`. Don't touch main. Report using the SHIP STATUS format in the new section.

## Shipping rule (every task)
A task is not done until the work is safe on GitHub.
1. Start every session by running scripts/repo-health.sh. Before new work, tell me about any uncommitted changes, any branch with commits not in origin/main, and any branch whose upstream is origin/main.
2. Start each task from an up-to-date origin/main on a new branch named for the task, created with `git checkout -b <name> --no-track origin/main` so it never inherits origin/main as its upstream. Never commit or push to main.
3. Before finishing: commit everything (code, docs, tests; `git status` must be clean), merge origin/main in, resolve docs conflicts keeping both sides (renumber decisions on collision), and run the full test suite from a clean build with zero warnings.
4. Push the branch to its own name with `git push -u origin <branch>`, and open a pull request if `gh` is available.
5. End every report with a SHIP STATUS block: branch, last commit, working tree clean (yes/no), pushed (yes/no), tests (count and warnings), pull request link, and the one action left for the founder.