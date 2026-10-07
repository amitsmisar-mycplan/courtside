# Progress

_Last updated: 2026-10-07_

| Step | What | Status |
|---|---|---|
| 1 | Models, `StorageManager`, clip-window math + tests | ✅ Done |
| 2 | Games list, import flow, empty states | ✅ Done |
| 3 | Playback marking | ✅ Done |
| 4 | Clip extraction + processing screen | ✅ Done |
| 5 | Clip player, nudge, share, delete | ✅ Done |
| 6 | `RecordingService` + `CaptureSessionController` | ▶ Unblocked — device confirmed 2026-10-07 |
| 7 | Resilience (thermal, interruption, disk) | ⏳ After step 6 |
| 8 | Acceptance test | ⏳ After step 7 |

**Since steps 1–5:** "Keep the full game video" now means keep forever (decision 0004).

**Feature: slow motion** ([spec](../feature-slow-motion.md), [decision 0007](../decisions/0007-slow-motion.md)) — built on `feature/slow-motion`; Simulator verification in [testing](../testing/simulator-verification.md#slow-motion).

**Next action:** install on the iPhone (free Apple ID signing), verify import/marking/clips/slow mo on the device — including whether slow mo needs the H.264 fallback (decision 0009) — then start step 6.

Remaining Simulator work before calling 1–5 fully verified: see [../testing/simulator-verification.md](../testing/simulator-verification.md#not-yet-verified).
