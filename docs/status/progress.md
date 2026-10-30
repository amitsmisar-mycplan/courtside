# Progress

_Last updated: 2026-10-30_

| Step | What | Status |
|---|---|---|
| 1 | Models, `StorageManager`, clip-window math + tests | ✅ Done |
| 2 | Games list, import flow, empty states | ✅ Done |
| 3 | Playback marking | ✅ Done |
| 4 | Clip extraction + processing screen | ✅ Done |
| 5 | Clip player, nudge, share, delete | ✅ Done |
| 6 | `RecordingService` + `CaptureSessionController` | 🧪 Built and unit-tested; needs the device test |
| 7 | Resilience (thermal, interruption, disk) | 🧪 Footage-safety parts built with step 6 ([0011](../decisions/0011-recording.md)); needs the device test |
| 8 | Acceptance test | ⏳ After step 7 |

**Since steps 1–5:** "Keep the full game video" now means keep forever (decision 0004).

**Feature: slow motion** ([spec](../feature-slow-motion.md), [decision 0007](../decisions/0007-slow-motion.md)) — built on `feature/slow-motion`; Simulator verification in [testing](../testing/simulator-verification.md#slow-motion).

**Slow-mo preview** now plays full screen, looping, turned to match the video, with a poster in the sheet ([0012](../decisions/0012-slowmo-fullscreen-preview.md)) — built on `feature/slowmo-fullscreen-preview`, Simulator-verified.

**Feature: game library** — opponent, score and notes on each game, edit screen, rows titled "vs Opponent", empty-state
buttons ([0013](../decisions/0013-game-library.md)). Built on `feature/game-library`; existing data migrates in place.

**Feature: undo mis-taps and delete clips** — repeatable Undo by mark ID in both marking screens; clip list with swipe and
multi-select delete ([0014](../decisions/0014-undo-stack-and-clip-delete.md)). Built on `feature/undo-and-clip-delete`.

**Next action:** install on the iPhone, verify import/marking/clips/slow mo, then run a short recording test (docs/testing/device-acceptance.md → First install), then the 90-minute acceptance test.

Remaining Simulator work before calling 1–5 fully verified: see [../testing/simulator-verification.md](../testing/simulator-verification.md#not-yet-verified).
