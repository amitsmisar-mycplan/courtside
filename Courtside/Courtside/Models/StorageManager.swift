import AVFoundation
import Foundation
import OSLog
import SwiftData

/// The only place that builds file URLs. Models store relative filenames; paths are rebuilt
/// here at read time because the app container path changes between installs.
enum StorageManager {
    private static let log = Logger(subsystem: "Courtside", category: "Storage")
    private static let partialMarker = ".partial"

    // MARK: Directories

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var gamesDirectory: URL {
        documentsDirectory.appending(path: "Games", directoryHint: .isDirectory)
    }

    static var clipsDirectory: URL {
        documentsDirectory.appending(path: "Clips", directoryHint: .isDirectory)
    }

    static var thumbnailsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// Creates the directories and excludes game/clip storage from iCloud backup.
    static func prepareDirectories() {
        for directory in [gamesDirectory, clipsDirectory, thumbnailsDirectory] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                log.error("Could not create \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for directory in [gamesDirectory, clipsDirectory] {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try url.setResourceValues(values)
            } catch {
                log.error("Could not exclude \(directory.lastPathComponent) from backup: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Filenames and URLs

    static func makeGameVideoFilename(id: UUID, fileExtension: String) -> String {
        "\(id.uuidString).\(fileExtension)"
    }

    static func makeClipFilename(id: UUID) -> String {
        "\(id.uuidString).mov"
    }

    /// `<clipUUID>-slowmo-<speed>.mov`, alongside the clip in `Clips/`.
    static func makeSlowMoFilename(clipID: UUID, speed: SlowMoSpeed) -> String {
        "\(clipID.uuidString)-slowmo-\(speed.fileComponent).mov"
    }

    static func gameVideoURL(filename: String) -> URL {
        gamesDirectory.appending(path: filename, directoryHint: .notDirectory)
    }

    static func gameVideoURL(for game: Game) -> URL {
        gameVideoURL(filename: game.videoFilename)
    }

    static func clipURL(filename: String) -> URL {
        clipsDirectory.appending(path: filename, directoryHint: .notDirectory)
    }

    static func clipURL(for clip: Clip) -> URL {
        clipURL(filename: clip.filename)
    }

    static func thumbnailURL(forClipID id: UUID) -> URL {
        thumbnailsDirectory.appending(path: "\(id.uuidString).jpg", directoryHint: .notDirectory)
    }

    /// In-progress sibling of `url` (`name.partial.ext`). Swept on launch if left behind.
    static func partialURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appending(path: "\(name)\(partialMarker).\(url.pathExtension)", directoryHint: .notDirectory)
    }

    // MARK: File info

    static func fileSize(at url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func availableCapacity() -> Int64 {
        let values = try? documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func removeFile(at url: URL) {
        guard fileExists(at: url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("Could not delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Moves `source` over `destination`, replacing any existing file.
    static func moveReplacing(_ source: URL, to destination: URL) throws {
        if fileExists(at: destination) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    // MARK: Record + file lifecycle

    @MainActor static func deleteGame(_ game: Game, in context: ModelContext) {
        removeFile(at: gameVideoURL(for: game))
        for clip in game.clips {
            removeClipFiles(clip)
        }
        context.delete(game)
        save(context)
    }

    @MainActor static func deleteClip(_ clip: Clip, in context: ModelContext) {
        removeClipFiles(clip)
        context.delete(clip)
        save(context)
    }

    /// Deletes the full game video but keeps the game, its marks and its clips.
    @MainActor static func deleteGameVideo(_ game: Game, in context: ModelContext) {
        removeFile(at: gameVideoURL(for: game))
        game.isVideoAvailable = false
        save(context)
    }

    static func removeThumbnail(forClipID id: UUID) {
        removeFile(at: thumbnailURL(forClipID: id))
    }

    /// Sweeps abandoned partial files and deletes full game videos past their retention window.
    ///
    /// Complete game videos with no `Game` record are never deleted here —
    /// `recoverRecordings(in:)` turns them into games.
    @MainActor static func performLaunchCleanup(in context: ModelContext, now: Date = .now) {
        for directory in [gamesDirectory, clipsDirectory] {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.contains(partialMarker) {
                log.info("Removing abandoned partial file \(url.lastPathComponent)")
                removeFile(at: url)
            }
        }

        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        for game in games where game.isVideoAvailable {
            if !fileExists(at: gameVideoURL(for: game)) {
                log.error("Game video missing for \(game.id); marking unavailable")
                game.isVideoAvailable = false
            } else if let expiresAt = game.videoExpiresAt, expiresAt <= now {
                log.info("Full video for \(game.id) passed retention; deleting")
                deleteGameVideo(game, in: context)
            }
        }
        save(context)
    }

    /// Deletes a clip's slow-motion render and clears its fields; the clip itself stays.
    @MainActor static func deleteSlowMo(of clip: Clip, in context: ModelContext) {
        removeSlowMoFile(of: clip)
        save(context)
    }

    /// Removes the slow-motion file and clears the fields without saving.
    static func removeSlowMoFile(of clip: Clip) {
        if let url = clip.slowMoURL { removeFile(at: url) }
        clip.slowMoFilename = nil
        clip.slowMoSpeed = nil
        clip.slowMoStartSeconds = nil
        clip.slowMoEndSeconds = nil
        clip.slowMoFileSize = nil
    }

    /// Turns interrupted recordings back into games, so a crash or force-quit mid-game never
    /// loses footage: games still at zero length get their real duration, and complete video
    /// files with no `Game` record get one. Unplayable files are left on disk untouched.
    @MainActor static func recoverRecordings(in context: ModelContext) async {
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []

        for game in games where game.isVideoAvailable && game.durationSeconds <= 0 {
            let url = gameVideoURL(for: game)
            if let duration = await playableDuration(of: url) {
                game.durationSeconds = duration
                game.videoFileSize = fileSize(at: url)
                log.info("Recovered interrupted recording \(game.videoFilename): \(duration)s")
            } else {
                log.error("Interrupted recording \(game.videoFilename) isn't playable; leaving it in place")
            }
        }

        let known = Set(games.map(\.videoFilename))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        for url in files where !known.contains(url.lastPathComponent) && !url.lastPathComponent.contains(partialMarker) {
            guard let duration = await playableDuration(of: url) else {
                log.error("Orphaned file \(url.lastPathComponent) isn't playable; leaving it in place")
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let game = Game(
                label: "Recovered — \(created.formatted(date: .abbreviated, time: .shortened))",
                recordedAt: created,
                videoFilename: url.lastPathComponent,
                durationSeconds: duration,
                source: .recorded,
                videoFileSize: fileSize(at: url)
            )
            context.insert(game)
            log.info("Recovered orphaned video \(url.lastPathComponent) as a game")
        }
        save(context)
    }

    private static func playableDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0
        else { return nil }
        return duration
    }

    private static func removeClipFiles(_ clip: Clip) {
        removeFile(at: clipURL(for: clip))
        if let url = clip.slowMoURL { removeFile(at: url) }
        removeThumbnail(forClipID: clip.id)
    }

    @MainActor private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            log.error("Save failed: \(error.localizedDescription)")
        }
    }
}
