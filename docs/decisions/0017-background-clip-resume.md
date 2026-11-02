# 0017 — Clip-making stops cleanly in the background and finishes later

**Status:** Accepted · 2026-11-02 (founder's "background clips and slow mo" fix; bug 1 in
[corpus-nov-1](../testing/corpus-nov-1.md#bugs-found))

## Problem
The spec wraps clip-making in `beginBackgroundTask` "so it survives brief backgrounding". A 4K clip can take longer than
iOS's ~30 s of background time, and the app only gave that time back after the export had unwound, which can be too late:
iOS kills an app that still holds expired background time. The remaining marks then sat on the game page until the parent
noticed and tapped "Make Clips".

## Decision
- **Stop cleanly at expiry.** When iOS says background time is running out, `ClipExtractor` cancels the current export,
  deletes that clip's partial file, and hands the background time back, all inside the expiry handler. Finished clips,
  their marks, every other mark, and the game video are untouched. The run ends in a new `interrupted` phase, separate
  from `cancelled` (the parent tapped Stop).
- **Finish later, automatically.**
  - *Back on screen:* the processing screen shows "Paused" while the app is in the background, then restarts by itself
    when the app is active again, under a "Finishing your clips" heading.
  - *Next launch* (iOS or the parent closed the app mid-run, or it crashed): the games list opens the same screen for
    each game with unfinished clips, one game at a time.
- **Which games resume:** a game is listed in `UnfinishedClips` (UserDefaults, game IDs only) when a run starts and
  removed when it ends on its own or the parent taps Stop. A run the system cut short stays listed. UserDefaults rather
  than a model field: no schema change and no migration, and the marks themselves (in SwiftData) stay the record of what
  is missing. Entries whose game is gone, whose video is deleted, or that have no pending marks are dropped. Failed
  exports aren't retried automatically (the run ended on its own), so a clip that always fails can't loop.
- **Never remade, never duplicated.** A clip's ID and filename now come from its mark's ID. A mark that already has a clip
  (same ID, or same tap time) is marked done and skipped. A finished clip file with no record, left when the app closed
  between writing the file and saving the record, is adopted instead of exported again. Partial files never become clips:
  they're deleted at expiry and swept at launch (decision 0005).
- **One batch at a time across the app.** `ClipExtractor.start` refuses to start while another batch is running, so a
  resumed batch can never run in parallel with a new one (exports stay serial).
- **Testable:** background time comes through a small `BackgroundTimeGranting` protocol; tests fire the expiry on demand.

## Not changed
- Exports still go through `ClipExtractor`'s single export path, same preset, re-encoded.
- The "Keep Courtside open until this finishes" hint stays: background time is still short, so staying open is fastest.

## Verified
- Unit tests (`ClipResumeTests`, real exports): expiry mid-batch stops with no partial, background time returned inside
  the handler; a fresh extractor then makes only the missing clips, with earlier clip files unchanged (same inode and
  date); an orphaned finished file is adopted; an existing clip isn't duplicated; Stop isn't resumed; two batches can't
  run at once.
- Simulator: started 2 clips from 4K footage, force-quit the app mid-clip, relaunched. "Finishing your clips" appeared
  by itself, the old partial was swept, and "2 clips ready" followed, with one file per mark.
- Device: still to do ([device-acceptance](../testing/device-acceptance.md#background-clip-making)).
