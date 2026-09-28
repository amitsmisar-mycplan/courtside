# Courtside — Phase 1 Technical Spec

> Source of truth for Phase 1, as written by the founder. Working name only. Replace throughout.
> Where the implementation deviates, see [../decisions/](../decisions/).

## What this is

An iOS app for a parent whose kid plays basketball. A game video goes in — either imported from the camera roll or recorded live from a tripod. The parent taps when something good happens. Individual clips come out.

Phase 1 has no AI, no backend, no accounts, no upload. Everything is on-device.

The user is a parent, not a coach and not a videographer. They are watching their child play. The app must work without them looking at it.

## Two paths in, one pipeline

A `Game` can be created two ways:

1. Import — pick an existing video from Photos or Files. Works in the Simulator.
2. Record — capture live from a tripod-mounted phone. Requires a physical device.

Both produce the identical result: a video file in `Documents/Games/` and a persisted `Game` record. Everything downstream is shared and must not know or care which path created the game. If you find yourself branching on source anywhere past game creation, that's a design error — tell me.

Marks can likewise be placed two ways:

1. During playback — play the imported game full-screen, tap during it. Simulator-friendly.
2. During recording — tap during live capture. Device-only.

Both write the same `Mark` rows. Clip extraction doesn't distinguish them.

Import is a shipping feature, not a test fixture. Parents already film games; the footage dies on their phones. "Import what you already shot, tap through it, get your kid's clips" is a complete product on its own.

## Build order

The founder currently has no iPhone available, so build in this order. Steps 1–5 are fully verifiable in the iOS Simulator.

1. Models, `StorageManager`, clip-window math + unit tests
2. Games list, import flow, empty states
3. Playback marking (full-screen tap during playback)
4. Clip extraction + processing screen
5. Clip player, nudge trim, share, delete
6. `RecordingService` protocol + live `CaptureSessionController` — device required
7. Resilience (thermal, interruption, disk) — device required
8. Acceptance test — device required

Do not start step 6 until I confirm I have a device.

## Non-goals for Phase 1

Explicitly do NOT build these. They are later phases.

- Player tracking, auto-crop, pose estimation, any computer vision
- Stat categories, box scores, season aggregates
- Cloud storage, sync, sign-in, accounts
- Reel stitching, music, transitions, text overlays
- Team rosters, schedules, multi-player support
- Android, iPad-specific layouts, Apple Watch, widgets

## Platform targets

- iOS 17.0 minimum (SwiftData requires it)
- Swift 5.9+, SwiftUI
- iPhone only
- Recording and playback-marking screens are landscape-locked; everything else portrait
- No third-party dependencies

## Architecture

Single target. No modules, no backend.

```
App/
  CourtsideApp.swift
Models/
  Game.swift
  Mark.swift
  Clip.swift
  StorageManager.swift
Import/
  VideoImporter.swift
Capture/                     # step 6, device-gated
  RecordingService.swift     # protocol
  CaptureSessionController.swift
Processing/
  ClipExtractor.swift
Views/
  GamesListView.swift
  ImportFlowView.swift
  PlaybackMarkingView.swift
  RecordingView.swift        # step 6
  ProcessingView.swift
  GameDetailView.swift
  ClipPlayerView.swift
```

Persistence: SwiftData.

Ownership rules. `StorageManager` is the only thing that builds a file URL. `ClipExtractor` is the only thing that runs an export. `CaptureSessionController` is the only thing that touches `AVCaptureSession`. Views render state and send intents — no AVFoundation, no file system, no queries beyond `@Query`.

## Data model

```swift
enum GameSource: String, Codable {
    case imported
    case recorded
}

@Model final class Game {
    var id: UUID
    var label: String            // "vs Lincoln, Nov 14"
    var recordedAt: Date
    var videoFilename: String    // RELATIVE filename only — see gotcha #1
    var durationSeconds: Double
    var source: GameSource
    var isProcessed: Bool
    @Relationship(deleteRule: .cascade) var marks: [Mark]
    @Relationship(deleteRule: .cascade) var clips: [Clip]
}

@Model final class Mark {
    var id: UUID
    var offsetSeconds: Double    // seconds from start of the game video
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

`source` is for display and diagnostics only. No logic branches on it.

## Clip window

Default clip = `[mark - 10s, mark + 3s]` → 13 seconds.

Rationale: a basketball possession runs roughly 8–12 seconds, and the parent taps after seeing the thing happen, so nearly all useful footage sits behind the tap.

Clamp to `[0, gameDuration]`. Make pre-roll and post-roll adjustable in Settings (pre-roll 5–20s, post-roll 0–10s), shipping the defaults above.

Unit test this. Cases: mark at t=2s with 10s pre-roll (clamps to 0); mark 1s before end (clamps to duration); mark at exactly 0; mark at exactly duration; zero-length game.

## Storage

- Game videos: `Documents/Games/<gameUUID>.mov`
- Clips: `Documents/Clips/<clipUUID>.mov`
- Exclude both directories from iCloud backup via `URLResourceValues.isExcludedFromBackup = true` — otherwise multi-GB game files will destroy the user's iCloud quota.

## Import flow

Entry point: "Add Game" on the games list → action sheet offering Import Video and Record Game (the latter disabled with "Coming soon" until step 6 lands).

**Picking.** Use `PhotosPicker` (SwiftUI, `PhotosUI`) filtered to `.videos`. Also offer `fileImporter` for `.movie` / `.video` so Files-app sources work. Avoid the older `UIImagePickerController`.

**Critical: copy, don't reference.** The picker gives a temporary URL that becomes invalid almost immediately. Copy the file into `Documents/Games/<uuid>.mov` before doing anything else. For file-importer URLs you must wrap access in `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`. Referencing instead of copying is the single most common way this feature breaks, and it breaks later, not immediately.

**Progress.** A 90-minute video is several GB and the copy is not instant. Show determinate progress. Do the copy off the main thread. Handle cancellation by deleting the partial file.

After copying:

- Read duration via `AVURLAsset` → `load(.duration)`
- Reject anything with no video track, with a clear message
- Accept whatever container Photos hands over — `.mov` and `.mp4` both work with AVFoundation; don't transcode on import
- Pre-flight free disk space; require 2× the source file size, and block with a clear message if short

**Label.** Sheet pre-filled with "Game — <date the video was created>", editable.

## Playback marking

This is how marks get placed without a camera, and it is a shipping feature in its own right.

Full-screen `AVPlayer`, landscape-locked, playing at 1x.

- The entire screen is the mark button, except a small control strip
- Controls: play/pause, scrub bar, jump back 10s, playback speed (1x, 1.5x, 2x), Done
- On tap: `UIImpactFeedbackGenerator(style: .heavy)`, a brief white border flash, mark count increments
- Mark offset = `player.currentTime().seconds` at tap
- Debounce to one mark per 2 seconds
- Undo button appears for 5 seconds after each mark
- Marks render as ticks on the scrub bar; tapping a tick seeks to it
- Allow re-entering marking on a game later to add more marks

Speed control is deliberate: a parent reviewing 90 minutes at home will watch at 2x, and timing tolerance is generous because the clip window is 13 seconds wide.

## Clip extraction

`AVAssetExportSession` with:

- `presetName: AVAssetExportPresetHEVCHighestQuality`
- `timeRange` set to the clip window
- `outputFileType: .mov`

Do not use passthrough export. It's faster but cuts only on keyframes, so clips land up to a second or two off from where the parent tapped. Correctness wins.

Serial, not parallel — concurrent exports cause memory pressure and thermal spikes.

Processing screen shows per-clip and total progress. Wrap in `beginBackgroundTask` so it survives brief backgrounding. If an individual clip fails, log it, skip it, and continue — one bad export must not abort the batch.

After processing, prompt: "Keep the full game video? (4.2 GB)" with Keep / Delete. Auto-delete after 7 days via a launch-time cleanup pass. For imported games note that the original is still in Photos, which makes deleting an easy choice.

## Games list (home)

- Newest first: label, date, source badge, clip count, duration, storage size
- Prominent "Add Game" button
- Swipe to delete with confirmation (cascades to video, clips, marks)
- Total storage used in the header

## Game detail

Grid of clip thumbnails via `AVAssetImageGenerator` at clip midpoint, cached to disk. Tap opens the player. Button to add more marks (re-enters playback marking).

## Clip player

- `AVPlayer`, loops by default
- Nudge start / nudge end: ±1s buttons that re-export with adjusted bounds. Highest-value editing feature and the only one worth building now — tap timing is often slightly off.
- Share via `UIActivityViewController`
- Delete

## Recording — step 6, device required

Build behind a protocol so the rest of the app never depends on it:

```swift
protocol RecordingService {
    func startRecording() async throws -> URL
    func stopRecording() async throws -> (url: URL, duration: Double)
    func mark() -> Double          // returns offset in seconds
}
```

`CaptureSessionController` implements it with `AVCaptureSession` + `AVCaptureMovieFileOutput`. Do not use `AVAssetWriter` — more control, far more ways to lose a game.

Settings: 1920x1080, 60fps, HEVC, back wide camera at zoom 1.0, audio on, stabilization off (tripod-mounted; stabilization only costs thermal headroom).

Focus and exposure locked after a 3-second settle, with a manual refocus button. Continuous autofocus hunts every time a player crosses frame — the single most common reason phone game film looks bad.

Timestamps from `CACurrentMediaTime()` deltas, never `Date()` (the system clock can jump mid-game).

Recording screen: full-screen tap target; long-press (1s) to stop, preventing accidental stops; refocus top-left; undo bottom-left; elapsed time, mark count, and thermal warning top-right. After 30s idle, dim to near-black with only elapsed time visible and lower screen brightness — tap still marks. This meaningfully extends battery across a 90-minute game.

Pre-flight: block if free disk < 8GB; warn if battery < 50% and not charging, if thermal state is already serious, or if Low Power Mode is on.

**Resilience — do not ship recording without all of this:**

- `AVCaptureSession.wasInterruptedNotification` → stop cleanly, save what exists
- `scenePhase` → `.background` → stop and save
- `thermalStateDidChangeNotification` → warn at serious, warn harder at critical
- Poll free space every 60s; stop and save below 1GB
- `UIApplication.shared.isIdleTimerDisabled = true` during capture, reset on every exit path
- On launch, an orphaned video file with no `Game` record becomes a recoverable game

Every failure path must leave a playable file and a `Game` record. Losing footage is the one unforgivable bug in this app — a parent gets one shot at their kid's game.

## Info.plist keys

- `NSCameraUsageDescription` — "Courtside uses the camera to record games."
- `NSMicrophoneUsageDescription` — "Courtside records game audio along with video."
- `NSPhotoLibraryAddUsageDescription` — "Save clips to your photo library."

`PhotosPicker` needs no read permission. Request the add permission only when the user taps save, never at launch.

## Gotchas that will bite

1. Never store absolute file URLs. The app container UUID changes between installs, so stored absolute paths break and every video appears lost. Store filenames only; rebuild paths at read time through `StorageManager`.
2. Copy imported videos immediately. Picker URLs are temporary. Referencing instead of copying fails later, not now, which makes it hard to diagnose.
3. Security-scoped resources from `fileImporter` must be balanced — start/stop access, or you leak.
4. `AVCaptureMovieFileOutput.maxRecordedDuration` must stay `.invalid`, or long games silently truncate.
5. Simulator has no camera. All capture testing is device-only.
6. `AVAssetImageGenerator` with zero time tolerance is accurate but slow — leave default tolerance for thumbnails.
7. Videos from Photos can carry rotation metadata. Respect the preferred transform on export or clips come out sideways.

## Verification

**Simulator (steps 1–5).** Drag a full-length game video onto the Simulator window to put it in Photos. Then: import it, confirm progress and correct duration; mark 20 times across the full video at 1x and 2x; confirm all 20 clips extract and each contains the moment tapped; nudge-trim one; share one; delete a game and confirm files are gone.

Test material should be a real 60–90 minute game shot from the stands, not a highlight reel. Badly-shot footage is the point.

**Device (steps 6–8).** Before relying on this for a real game:

1. Record 90 continuous minutes on a tripod in a gym-sized room
2. Tap at least 20 marks spread across the full duration
3. Confirm no interruption, no thermal shutdown, and >20% battery remaining from a 100% start
4. Confirm all 20 clips extract and contain the tapped moments
5. Force-quit mid-recording; confirm the partial game is recoverable
6. Take a phone call mid-recording; confirm graceful stop and save

Do not skip #1. A 90-minute capture behaves nothing like a 5-minute test.
