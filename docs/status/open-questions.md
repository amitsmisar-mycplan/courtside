# Open questions

| # | Question | Raised | Answer |
|---|---|---|---|
| 1 | Should "Keep the full game video" mean keep forever, with 7-day auto-delete only if the prompt is never answered? Currently Keep = keep for 7 days. | 2026-09-26 | **Forever.** Auto-delete only if unanswered. Implemented 2026-09-28 — see [decision 0004](../decisions/0004-video-retention-and-nudge.md) |
| 2 | Clip export speed on real hardware (Simulator: ~15 s per 13 s clip, software HEVC). Measure on the first device; 20 clips from 4K on an older phone may take minutes. | 2026-09-26 | _measure on device_ |
| 3 | Portrait videos appear tiny in the landscape-locked marking screen. Options: (a) lock marking to the video's own orientation, (b) allow both orientations when marking, (c) leave as is — most game footage is landscape. | 2026-09-30 | **(b) both orientations.** Implemented 2026-10-01 — [decision 0008](../decisions/0008-marking-any-orientation.md) |
| 4 | Very short clips under-report frame rate (a 1.5 s 30 fps clip reads 26 fps), so slow mo is switched off with a confusing "26 fps" message. Options: (a) leave it — clips that short are rare; (b) treat 24–29 fps as "30" only when the clip is under ~3 s; (c) say "too short for slow motion" instead. | 2026-10-06 | **(a) Leave it** — clips that short are rare. No code change. |
