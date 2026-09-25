# Courtside — Step 1 Technical Spec

**Working name only.** Replace throughout.

## What this is

An iOS app for a parent filming their kid's basketball game from a tripod. Record the
full game, tap the screen when something good happens, get individual clips afterward.

**Step 1 has no AI, no backend, no accounts, no upload.** Everything is on-device.
Success is: the founder uses this for three real games and gets watchable clips out.

## Non-goals for Step 1

Explicitly do NOT build these yet. They are later steps.

- Player tracking, auto-crop, or any computer vision
- Stat categories or box scores
- Cloud sync, user accounts, sign-in
- Reel stitching, music, transitions
- Team or roster management
- Android, iPad-specific layouts, Apple Watch

## Platform targets

- iOS 17.0 minimum (SwiftData requires it)
- Swift 5.9+, SwiftUI
- iPhone only, **landscape orientation locked** in the recording screen
- Portrait allowed elsewhere
- Test device: whatever iPhone the founder actually owns. Do not assume Pro hardware.

## Architecture

Single-target app. No modules, no backend, no third-party dependencies.

```
App/
  CourtsideApp.swift
Models/
  Game.swift
  Mark.swift
  Clip.swift
  StorageManager.swift
Capture/
  CaptureSessionController.swift
  RecordingViewModel.swift
Processing/
  ClipExtractor.swift
Views/
  GamesListView.swift
  RecordingView.swift
  ProcessingView.swift
  GameDetailView.swift
  ClipPlayerView.swift
```

Persistence: **SwiftData**.

## Data model

```swift
@Model final class Game {
    var id: UUID
    var label: String            // "vs Lincoln, Nov 14"
    var recordedAt: Date
    var videoFilename: String    // RELATIVE filename only — see gotcha #1
    var durationSeconds: Double
    var isProcessed: Bool
    @Relationship(deleteRule: .cascade) var marks: [Mark]
    @Relationship(deleteRule: .cascade) var clips: [Clip]
}

@Model final class Mark {
    var id: UUID
    var offsetSeconds: Double    // seconds from recording start
    var createdAt: Date
    var game: Game?
}

@Model final class Clip {
    var id: UUID
    var filename: String         // RELATIVE filename only
    var startSeconds: Double     // in source game video
    var endSeconds: Double
    var createdAt: Date
    var game: Game?
}
```

### Clip window

Default clip = `[mark - 10s, mark + 3s]` → 13 seconds.

Rationale: a basketball possession runs roughly 8–12 seconds, and the parent taps
*after* seeing the thing happen, so almost all useful footage is behind the tap.

Clamp to `[0, gameDuration]`. Make pre-roll and post-roll user-adjustable in Settings
(pre-roll 5–20s, post-roll 0–10s) but ship the defaults above.

## Storage

- Game videos: `Documents/Games/<gameUUID>.mov`
- Clips: `Documents/Clips/<clipUUID>.mov`
- Exclude both from iCloud backup (`URLResourceValues.isExcludedFromBackup = true`) —
  otherwise multi-GB game files will wreck the user's iCloud quota.

`StorageManager` owns all path construction. Nothing else in the app builds a file URL.

## Capture

Use `AVCaptureSession` + `AVCaptureMovieFileOutput`. Do not use `AVAssetWriter` — more
control, but many more ways to lose a whole game's footage.

### Settings

- Resolution: 1920x1080
- Frame rate: 60 fps
- Codec: HEVC (`movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)`)
- Camera: back wide (`.builtInWideAngleCamera`), video zoom factor 1.0
- Audio: enabled, default mic
- Stabilization: **off**. The phone is on a tripod; stabilization only costs thermal
  headroom and can introduce warping.

Roughly 4–5 GB per hour. That's the tradeoff being made deliberately: 4K would look
marginally better and roughly triple storage, thermal load, and export time.

### Focus and exposure

Lock both after a 3-second settling period at record start
(`.locked` focus mode, `.locked` exposure mode). Gym lighting is constant, and
continuous autofocus will hunt every time a player crosses the frame — which looks
terrible and is the single most common complaint about phone-shot game film.

Provide a "refocus" button on the recording screen for when it gets it wrong.

### Timestamps

On `fileOutput(_:didStartRecordingTo:from:)`, store `CACurrentMediaTime()` as
`recordingStartTime`. Each mark's offset is `CACurrentMediaTime() - recordingStartTime`.

Do not use `Date()` — it can jump if the system clock syncs mid-game.

## Recording screen — the most important UI in the app

**Design constraint: the parent is watching their kid, not the phone.** Every
interaction must work without looking at the screen.

Layout (landscape):

- Full-screen camera preview
- **The entire screen is the mark button**, except:
  - Stop button, bottom-right, requires a 1-second long-press to prevent accidental stops
  - Refocus button, top-left, small
  - Undo button, bottom-left, appears for 5 seconds after each mark
- Top-right overlay: elapsed time, mark count, thermal warning if any

On tap:
- `UIImpactFeedbackGenerator(style: .heavy)` fires immediately — this is the primary
  confirmation, since the user isn't looking
- Brief border flash (white, 0.2s ease-out)
- Mark count increments

Debounce marks to one per 2 seconds to swallow double-taps.

### Dim mode

After 30 seconds without interaction, fade the preview to near-black with just the
elapsed time visible, and set `UIScreen.main.brightness` low. Tap still registers a mark.
Any button press restores. This meaningfully extends battery over a 90-minute game.

## Pre-flight checks

Before `startRecording()`, block and warn on:

1. **Free disk space** < 8 GB → hard block with a clear message. This is the #1 way a
   parent loses a game.
2. **Battery** < 50% and not charging → warn, allow override. Recommend a battery pack.
3. **Thermal state** already `.serious` or `.critical` → warn.
4. Low Power Mode enabled → warn, it can throttle capture.

## During recording — resilience

A 90-minute continuous capture will hit real problems. Handle all of these.

- **`AVCaptureSession.wasInterruptedNotification`** — phone call, another app grabbing
  the camera, Control Center. On interruption, stop recording cleanly and save what
  exists. On resume, show a "recording stopped" screen with the partial game preserved.
  Never silently discard.
- **`UIApplication.shared.isIdleTimerDisabled = true`** for the whole recording session.
  Set it back to `false` on stop, including on every error path.
- **Backgrounding stops capture.** Detect `scenePhase` change to `.background`, stop and
  save. Warn the user in advance ("don't switch apps during the game").
- **Thermal monitoring** — observe `ProcessInfo.processInfo.thermalStateDidChangeNotification`.
  At `.serious`, show a persistent warning. At `.critical`, warn that iOS may stop the
  camera and suggest removing the case.
- **Disk exhaustion mid-game** — poll free space every 60 seconds. Below 1 GB, stop
  recording and save.

Every failure path must leave a playable file and a `Game` record. Losing footage is the
one unforgivable bug in this app.

## Processing

After stop, go to `ProcessingView`. Extract clips serially, one at a time.

Use `AVAssetExportSession` with:
- `presetName: AVAssetExportPresetHEVCHighestQuality`
- `timeRange` set to the clip window
- `outputFileType: .mov`

**Do not use passthrough export.** It's much faster but only cuts on keyframes, so clips
land up to a second or two off from where the parent tapped. Re-encoding a 13-second
clip takes a couple of seconds on modern hardware. Correctness wins here.

Serial, not parallel — concurrent exports cause memory pressure and thermal spikes right
after a long recording when the phone is already hot.

Show per-clip progress and total. Allow backgrounding during processing with a
`beginBackgroundTask` so it survives briefly if the user leaves.

After processing, prompt: **"Keep the full game video? (4.2 GB)"** with Keep / Delete.
Default to Delete after 7 days via a cleanup pass on launch. Storage is the reason people
uninstall camera apps.

## Games list (home)

- List of games, newest first: label, date, clip count, duration, storage size
- Prominent "Record Game" button
- Swipe to delete (cascade deletes video, clips, marks — confirm first, it's destructive)
- Total storage used, shown in the header

New game creation: a single sheet asking for a label, pre-filled with
"Game — <today's date>". Don't build opponent pickers or schedules.

## Game detail

Grid of clip thumbnails (generate with `AVAssetImageGenerator` at clip midpoint, cache
them). Tap opens the player.

## Clip player

- `AVPlayer` with standard controls, loops by default
- **Nudge start / nudge end**: ±1s buttons that re-export the clip with adjusted bounds.
  This is the highest-value editing feature and the only one worth building now — the
  tap timing will often be slightly off.
- Share button → `UIActivityViewController` (Messages, AirDrop, Save to Photos)
- Delete

Saving to Photos needs `NSPhotoLibraryAddUsageDescription`. Request only when tapped, not
at launch.

## Info.plist keys

- `NSCameraUsageDescription` — "Courtside uses the camera to record games."
- `NSMicrophoneUsageDescription` — "Courtside records game audio along with video."
- `NSPhotoLibraryAddUsageDescription` — "Save clips to your photo library."
- `UISupportedInterfaceOrientations` — all; lock landscape per-view in RecordingView.

## Gotchas that will bite

1. **Never store absolute file URLs.** The app container UUID changes between installs
   and some updates, so stored absolute paths break and all video appears lost. Store
   filenames only and rebuild paths at read time via `StorageManager`.
2. `isIdleTimerDisabled` must be reset on every exit path, including crashes-adjacent
   ones like scene disconnection.
3. `AVCaptureMovieFileOutput` has a `maxRecordedDuration` — leave it unset (`.invalid`),
   or a long game silently truncates.
4. Simulator has no camera. All capture testing must be on a real device.
5. Thumbnails: `AVAssetImageGenerator.requestedTimeToleranceBefore/After = .zero` gives
   accurate frames but is slow. Leave default tolerance for thumbnails.

## Acceptance test before the first real game

Run this end to end, on the actual device, before relying on it:

1. Record 90 continuous minutes on a tripod in a gym (or any large room)
2. Tap at least 20 marks spread across the full duration
3. Confirm: no interruption, no thermal shutdown, phone finishes above 20% battery when
   started at 100%
4. Confirm all 20 clips extract, and each clip actually contains the moment tapped
5. Force-quit the app mid-recording and confirm the partial game is recoverable
6. Take a phone call mid-recording and confirm graceful stop and save

Do not skip #1. A 90-minute continuous capture behaves very differently from a
5-minute test.

## Build order

1. Camera preview + record to file + games list. No marks.
2. Marks + haptics + undo.
3. Clip extraction + processing screen.
4. Clip player + share.
5. Nudge trim, dim mode, storage cleanup.
6. Resilience: interruptions, thermal, disk checks.

Steps 1–4 are the walking skeleton. Get there first, then harden.
