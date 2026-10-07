# Progress

_Last updated: 2026-10-07_

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

**Next action:** install on the iPhone, verify import/marking/clips/slow mo, then run a short recording test (docs/testing/device-acceptance.md → First install), then the 90-minute acceptance test.

Remaining Simulator work before calling 1–5 fully verified: see [../testing/simulator-verification.md](../testing/simulator-verification.md#not-yet-verified).
