import AVFoundation
import QuartzCore
import SwiftData
import XCTest
@testable import Courtside

/// Real-footage scenario for games with more than one video (decision 0022). Skipped unless
/// `COURTSIDE_CORPUS_DIR` is set. Takes the two smallest videos there (or the two named in
/// `COURTSIDE_CORPUS_FILES`), imports them as Part 1 and Part 2 of one game, marks
/// `COURTSIDE_MARKS_PER_VIDEO` (default 3) taps in each, makes every clip, trims one, saves one
/// vertical, shares one with the label, deletes the game, and checks no file is left behind.
/// Source videos are read only. Results print as `MULTIPART|` lines.
extension CorpusStressTests {
    func testMultiPartGame() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["COURTSIDE_CORPUS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_CORPUS_DIR to run the multi-part real-footage scenario.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let marksPerPart = max(1, Int(env["COURTSIDE_MARKS_PER_VIDEO"] ?? "") ?? 3)
        let named = (env["COURTSIDE_CORPUS_FILES"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let videos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .filter { named.isEmpty || named.contains($0.lastPathComponent) }
            .sorted { StorageManager.fileSize(at: $0) < StorageManager.fileSize(at: $1) }
        let sources = Array(videos.prefix(2))
        guard sources.count == 2 else { return XCTFail("need two videos in \(folder.path)") }
        // In the order they were filmed, as a parent would add them.
        let ordered = sources.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sourceSizes = ordered.map(StorageManager.fileSize(at:))
        log("sources", ordered.map { "\($0.lastPathComponent) \(Format.bytes(StorageManager.fileSize(at: $0)))" }.joined(separator: ", "))

        StorageManager.prepareDirectories()
        LabelledExportCache.shared.removeAll()
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let before = FileSnapshot.take()
        var game: Game?
        defer {
            // Whatever happens: the game and its files, then anything else this run created.
            if let game, game.modelContext != nil { StorageManager.deleteGame(game, in: context) }
            LabelledExportCache.shared.removeAll()
            FileSnapshot.take().added(since: before).forEach(StorageManager.removeFile(at:))
        }

        // 1. Import Part 1 as a new game, then Part 2 with Add Video: the same importer for both.
        var start = Date()
        let first = try await VideoImporter.importFromFile(at: ordered[0]) { _ in }
        let newGame = Game(id: first.videoID, label: "", recordedAt: first.createdAt ?? .now, videoFilename: first.filename,
                           durationSeconds: first.durationSeconds, source: .imported, videoFileSize: first.fileSize)
        newGame.team = "Eagles"
        newGame.opponent = "Lakers"
        context.insert(newGame)
        try context.save()
        game = newGame
        let second = try await VideoImporter.importFromFile(at: ordered[1]) { _ in }
        try StorageManager.addPart(second, to: newGame, in: context)
        log("import", String(format: "%.1f s for both", Date().timeIntervalSince(start)))
        let parts = newGame.orderedParts
        XCTAssertEqual(parts.map(\.title), ["Part 1", "Part 2"])
        XCTAssertEqual(newGame.durationSeconds, first.durationSeconds + second.durationSeconds, accuracy: 0.001)
        for (part, source) in zip(parts, ordered) {
            XCTAssertEqual(StorageManager.fileSize(at: StorageManager.videoURL(for: part)), StorageManager.fileSize(at: source), "\(part.title) is a copy")
            XCTAssertNotEqual(StorageManager.videoURL(for: part).standardizedFileURL, source.standardizedFileURL)
        }
        XCTAssertEqual(newGame.storageBytes, first.fileSize + second.fileSize)

        // 2. Marks in each part through the marking screen's session: one early, one mid, one near the end.
        var clock: CFTimeInterval = 50_000
        for part in parts {
            let session = MarkingSession(game: newGame, part: part, context: context, clock: { clock })
            let times = Self.markTimes(count: marksPerPart, duration: part.durationSeconds)
            for time in times {
                session.seek(to: time)
                let deadline = Date.now.addingTimeInterval(15)
                while Date.now < deadline, abs(session.player.currentTime().seconds - time) >= 0.05 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(session.placeMark(), "\(part.title) tap at \(time)")
                clock += 2.5
            }
            XCTAssertEqual(session.markCount, marksPerPart, "\(part.title) shows only its own marks")
            session.tearDown()
            XCTAssertEqual(part.marks.count, marksPerPart)
        }
        XCTAssertEqual(newGame.marks.count, marksPerPart * 2)

        // 3. Every clip, serially, through ClipExtractor.
        start = Date()
        let extractor = ClipExtractor()
        XCTAssertTrue(extractor.start(game: newGame, context: context))
        while extractor.phase == .running { try await Task.sleep(for: .milliseconds(250)) }
        log("clips", String(format: "%d made, %d failed, %.1f s", extractor.completed, extractor.failed, Date().timeIntervalSince(start)))
        XCTAssertEqual(extractor.completed, marksPerPart * 2)
        XCTAssertEqual(newGame.clips.count, marksPerPart * 2, "one clip per mark")
        XCTAssertEqual(Set(newGame.clips.map(\.id)), Set(newGame.marks.map(\.id)))
        XCTAssertEqual(Set(newGame.clips.map(\.filename)).count, newGame.clips.count, "no two clips share a file")
        for clip in newGame.sortedClips {
            let part = try XCTUnwrap(clip.part)
            let expected = ClipWindow.around(mark: clip.markSeconds ?? 0, preRoll: ClipSettings.preRoll,
                                             postRoll: ClipSettings.postRoll, gameDuration: part.durationSeconds)
            XCTAssertEqual(clip.startSeconds, expected.start, accuracy: 0.001)
            XCTAssertEqual(clip.endSeconds, expected.end, accuracy: 0.001, "clamped to \(part.title)")
            let duration = try await AVURLAsset(url: clip.fileURL).load(.duration).seconds
            XCTAssertEqual(duration, expected.duration, accuracy: 0.15)
            log("clip", String(format: "%@ %.2f–%.2f s, file %.2f s", part.title, clip.startSeconds, clip.endSeconds, duration))
        }
        XCTAssertEqual(newGame.sortedClips.map { $0.part!.index }, Array(repeating: 0, count: marksPerPart) + Array(repeating: 1, count: marksPerPart))

        // 4. Trim the last clip of Part 2 out to its limits: never past Part 2's end.
        let lastClip = try XCTUnwrap(newGame.sortedClips.last)
        let bounds = ClipWindow.trimBounds(mark: lastClip.markTime, gameDuration: parts[1].durationSeconds, current: lastClip.window)
        XCTAssertLessThanOrEqual(bounds.end, parts[1].durationSeconds + 0.001)
        let wider = lastClip.window.trimming(.start, to: lastClip.startSeconds - 5, within: bounds)
            .trimming(.end, to: lastClip.endSeconds + 5, within: bounds)
        start = Date()
        try await ClipExtractor.trim(lastClip, to: wider, context: context) { _ in }
        let trimmed = try await AVURLAsset(url: lastClip.fileURL).load(.duration).seconds
        log("trim", String(format: "Part 2 clip to %.2f–%.2f s, file %.2f s, %.1f s", wider.start, wider.end, trimmed, Date().timeIntervalSince(start)))
        XCTAssertEqual(trimmed, wider.duration, accuracy: 0.15)

        // 5. Vertical save of a Part 1 clip, and a labelled share of a Part 2 clip.
        let firstClip = try XCTUnwrap(newGame.sortedClips.first)
        let photos = MultiPartPhotos()
        let export = ClipExportSession(clipID: firstClip.id, source: firstClip.fileURL, label: .forExport(game: newGame, mode: .openAndClose), photos: photos)
        start = Date()
        export.export(.vertical)
        await export.finish()
        XCTAssertEqual(export.phase, .saved(.vertical))
        XCTAssertEqual(photos.sizes, [CGSize(width: 1080, height: 1920)])
        log("vertical", String(format: "Part 1 clip, %.1f s", Date().timeIntervalSince(start)))

        let sharer = MultiPartSharer()
        let share = ClipShareSession(clipID: lastClip.id, source: lastClip.fileURL, label: .forExport(game: newGame, mode: .openAndClose), sharer: sharer)
        XCTAssertTrue(share.addsLabel)
        start = Date()
        share.start()
        await share.finish()
        XCTAssertEqual(share.phase, .finished)
        XCTAssertEqual(sharer.shared.count, 1)
        log("share", String(format: "Part 2 clip with label, %.1f s", Date().timeIntervalSince(start)))

        // 6. Delete the game: every part's video, every clip, thumbnail and cached copy goes.
        StorageManager.deleteGame(newGame, in: context)
        game = nil
        let left = FileSnapshot.take().added(since: before)
        XCTAssertEqual(left.map(\.lastPathComponent), [], "no stray files")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GamePart>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Mark>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 0)
        XCTAssertEqual(ordered.map(StorageManager.fileSize(at:)), sourceSizes, "source videos untouched")
        log("delete", "game removed, \(left.count) files left")
    }

    /// `count` tap times: the first in the first 10 s, the last in the final 3 s, the rest spread between.
    static func markTimes(count: Int, duration: Double) -> [Double] {
        guard count > 1 else { return [duration / 2] }
        let first = min(5, duration * 0.1), last = max(first, duration - 1.5)
        return (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
    }

    private func log(_ step: String, _ message: String) {
        print("MULTIPART|\(step)|\(message)")
    }
}

private final class MultiPartPhotos: PhotoLibrarySaving, @unchecked Sendable {
    var sizes: [CGSize] = []
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws {
        sizes.append((try? await SlowMoComposer.displaySize(of: url)) ?? .zero)
    }
}

@MainActor
private final class MultiPartSharer: FileSharing {
    var shared: [URL] = []
    func share(_ url: URL) async { shared.append(url) }
}
