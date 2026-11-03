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

    /// Videos rendered for posting. Temporary: removed once saved, and swept on launch.
    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    static var thumbnailsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// Creates the directories and excludes game/clip storage from iCloud backup.
    static func prepareDirectories() {
        for directory in [gamesDirectory, clipsDirectory, thumbnailsDirectory, exportsDirectory] {
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

    /// A new temporary file for an export, e.g. `<clip>-vertical-<random>.mov`.
    static func makeExportURL(clipID: UUID, format: ExportFormat) -> URL {
        exportsDirectory.appending(path: "\(clipID.uuidString)-\(format.rawValue)-\(UUID().uuidString.prefix(8)).mov")
    }

    /// Removes a temporary export, and its partial file if one was left.
    static func removeExport(at url: URL) {
        removeFile(at: url)
        removeFile(at: partialURL(for: url))
    }

    /// Removes every temporary export of a clip, cached labelled copies included (decision 0021).
    static func removeExports(forClipID id: UUID) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: exportsDirectory.path)) ?? []
        for name in names where name.hasPrefix(id.uuidString) {
            removeFile(at: exportsDirectory.appending(path: name))
        }
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

    /// A part's video (decision 0022).
    static func videoURL(for part: GamePart) -> URL {
        gameVideoURL(filename: part.videoFilename)
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

    /// Removes every part's video and every clip's files, then the game (its parts, marks and clips go with it).
    @MainActor static func deleteGame(_ game: Game, in context: ModelContext) {
        for part in game.parts {
            removeFile(at: videoURL(for: part))
        }
        for clip in game.clips {
            removeClipFiles(clip)
        }
        context.delete(game)
        save(context)
    }

    @MainActor static func deleteClip(_ clip: Clip, in context: ModelContext) {
        deleteClips([clip], in: context)
    }

    /// Removes each clip's exported file, slow-mo render and thumbnail, then the records — the clip
    /// and the mark it was made from, so the game's mark count matches its clips — in one save.
    @MainActor static func deleteClips(_ clips: [Clip], in context: ModelContext) {
        for clip in clips {
            if let mark = sourceMark(of: clip) { context.delete(mark) }
            removeClipFiles(clip)
            context.delete(clip)
        }
        save(context)
    }

    /// The mark a clip was cut from: the mark with the clip's ID (clips are named after their mark),
    /// else the extracted mark at the clip's stored tap time in the same part. Clips made before the
    /// tap time was stored have no reliable match, so their mark is left alone.
    @MainActor private static func sourceMark(of clip: Clip) -> Mark? {
        guard let marks = clip.game?.marks else { return nil }
        if let mark = marks.first(where: { $0.id == clip.id }) { return mark }
        guard let tap = clip.markSeconds else { return nil }
        let part = clip.resolvedPart
        return marks.first { $0.isExtracted && $0.resolvedPart === part && abs($0.offsetSeconds - tap) < 0.001 }
    }

    /// Deletes every part's video but keeps the game, its marks and its clips ("Delete…" on a kept game).
    @MainActor static func deleteGameVideo(_ game: Game, in context: ModelContext) {
        deleteVideos(of: game.parts, in: context)
    }

    /// The keep/delete prompt's "Delete": only the videos of parts whose clips are all made, so a
    /// part added but not yet marked is kept (decision 0022).
    @MainActor static func deleteProcessedVideos(of game: Game, in context: ModelContext) {
        deleteVideos(of: game.processedAvailableParts, in: context)
    }

    @MainActor private static func deleteVideos(of parts: [GamePart], in context: ModelContext) {
        for part in parts where part.isVideoAvailable {
            removeFile(at: videoURL(for: part))
            part.isVideoAvailable = false
        }
        save(context)
    }

    /// Adds an imported video to `game` as its next part.
    @MainActor @discardableResult
    static func addPart(_ video: ImportedVideo, to game: Game, in context: ModelContext) throws -> GamePart {
        let part = GamePart(
            id: video.videoID,
            index: game.nextPartIndex,
            videoFilename: video.filename,
            durationSeconds: video.durationSeconds,
            videoFileSize: video.fileSize,
            recordedAt: video.createdAt ?? .now
        )
        context.insert(part)
        part.game = game
        try context.save()
        return part
    }

    // MARK: Parts migration (decision 0022)

    /// Copies the database files once, before the parts schema first opens them, so the data from
    /// before parts can always be restored. Never overwritten; videos are never part of it.
    static func backUpStoreBeforeParts(storeURL: URL) {
        let backup = storeURL.deletingLastPathComponent().appending(path: "StoreBackup-0022", directoryHint: .isDirectory)
        guard !fileExists(at: backup) else { return }
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: storeURL.path + suffix)
                guard fileExists(at: file) else { continue }
                try FileManager.default.copyItem(at: file, to: backup.appending(path: file.lastPathComponent))
            }
            log.info("Backed up the game database before parts")
        } catch {
            log.error("Database backup before parts failed: \(error.localizedDescription)")
        }
    }

    /// Gives every game from before parts its "Part 1": its old video, with all its marks and clips.
    /// No file is touched and times don't change (Part 1 is the old whole video). Safe to run again:
    /// games that have parts are skipped. Returns how many games were given a part.
    @MainActor @discardableResult
    static func migrateToParts(in context: ModelContext) -> Int {
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        var migrated = 0
        for game in games where game.parts.isEmpty {
            let part = GamePart(
                index: 0,
                videoFilename: game.legacyVideoFilename,
                durationSeconds: game.legacyDurationSeconds,
                videoFileSize: game.legacyVideoFileSize,
                recordedAt: game.recordedAt
            )
            part.isVideoAvailable = game.legacyIsVideoAvailable
            part.processedAt = game.legacyProcessedAt
            context.insert(part)
            part.game = game
            for mark in game.marks where mark.part == nil { mark.part = part }
            for clip in game.clips where clip.part == nil { clip.part = part }
            migrated += 1
        }
        guard migrated > 0 else { return 0 }
        do {
            try context.save()
            log.info("Gave \(migrated) games their Part 1")
        } catch {
            // Nothing is lost: the legacy fields are still there, so the next launch tries again.
            log.error("Parts migration save failed: \(error.localizedDescription)")
            context.rollback()
            return 0
        }
        return migrated
    }

    static func removeThumbnail(forClipID id: UUID) {
        removeFile(at: thumbnailURL(forClipID: id))
    }

    /// Sweeps abandoned partial files and leftover exports, and deletes part videos past their retention window.
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

        // Exports are only kept until saved or, for labelled copies, while the app runs (decision 0021).
        for url in (try? FileManager.default.contentsOfDirectory(at: exportsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            log.info("Removing leftover export \(url.lastPathComponent)")
            removeFile(at: url)
        }

        // Per part (decision 0022): each part's video expires 7 days after its own clips were made.
        let parts = (try? context.fetch(FetchDescriptor<GamePart>())) ?? []
        for part in parts where part.isVideoAvailable {
            if !fileExists(at: videoURL(for: part)) {
                log.error("Video missing for part \(part.id); marking unavailable")
                part.isVideoAvailable = false
            } else if let expiresAt = part.videoExpiresAt, expiresAt <= now {
                log.info("Video for part \(part.id) passed retention; deleting")
                removeFile(at: videoURL(for: part))
                part.isVideoAvailable = false
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
        let parts = (try? context.fetch(FetchDescriptor<GamePart>())) ?? []

        for part in parts where part.isVideoAvailable && part.durationSeconds <= 0 {
            let url = videoURL(for: part)
            if let duration = await playableDuration(of: url) {
                part.durationSeconds = duration
                part.videoFileSize = fileSize(at: url)
                log.info("Recovered interrupted recording \(part.videoFilename): \(duration)s")
            } else {
                log.error("Interrupted recording \(part.videoFilename) isn't playable; leaving it in place")
            }
        }

        // Every part's file is known, plus each game's video from before parts (decision 0022), so
        // only a file no record points to is an orphan.
        let known = Set(parts.map(\.videoFilename)).union(games.map(\.legacyVideoFilename))
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
                videoFileSize: fileSize(at: url),
                team: LabelSettings.myTeam
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
        removeExports(forClipID: clip.id)
    }

    @MainActor private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            log.error("Save failed: \(error.localizedDescription)")
        }
    }
}
