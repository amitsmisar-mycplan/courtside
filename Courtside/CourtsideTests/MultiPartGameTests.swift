import AVFoundation
import QuartzCore
import SwiftData
import XCTest
@testable import Courtside

/// Games with more than one video (decision 0022): the model, clips cut from their own part and
/// clamped to it, trim, marking per part, retention per part, recovery, and deletion with no
/// files left behind. Real exports, in-memory store; every file made is removed afterwards.
@MainActor
final class MultiPartGameTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var createdFiles: [URL] = []
    private var suiteName = ""
    private var defaults: UserDefaults!

    /// Part 1 is dark, Part 2 bright, so a clip shows which video it was cut from.
    private static let part1Gray: Int32 = 50
    private static let part2Gray: Int32 = 200

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.prepareDirectories()
        suiteName = "MultiPartGameTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Helpers

    /// A video in `Games/`, as the importer leaves it.
    private func makeVideo(seconds: Int, gray: Int32) async throws -> ImportedVideo {
        let id = UUID()
        let filename = StorageManager.makeGameVideoFilename(id: id, fileExtension: "mov")
        let url = StorageManager.gameVideoURL(filename: filename)
        createdFiles.append(url)
        try await TestMedia.makeVideo(at: url, seconds: seconds, fps: 30, gray: gray, withTone: true)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        return ImportedVideo(videoID: id, filename: filename, durationSeconds: duration, createdAt: .now, fileSize: StorageManager.fileSize(at: url))
    }

    /// A game made the way the import screen makes one, plus a second video added with Add Video.
    private func makeTwoPartGame(part1Seconds: Int = 20, part2Seconds: Int = 12) async throws -> Game {
        let first = try await makeVideo(seconds: part1Seconds, gray: Self.part1Gray)
        let game = Game(id: first.videoID, label: "Two halves", recordedAt: .now, videoFilename: first.filename,
                        durationSeconds: first.durationSeconds, source: .imported, videoFileSize: first.fileSize)
        context.insert(game)
        try context.save()
        let second = try await makeVideo(seconds: part2Seconds, gray: Self.part2Gray)
        try StorageManager.addPart(second, to: game, in: context)
        return game
    }

    private func mark(_ offset: Double, in part: GamePart, of game: Game) -> Mark {
        let mark = Mark(offsetSeconds: offset)
        context.insert(mark)
        mark.game = game
        mark.part = part
        try? context.save()
        track(mark.id)
        return mark
    }

    /// The files a clip made from this mark would have.
    private func track(_ clipID: UUID) {
        let clip = StorageManager.clipURL(filename: StorageManager.makeClipFilename(id: clipID))
        createdFiles += [clip, StorageManager.partialURL(for: clip), StorageManager.thumbnailURL(forClipID: clipID)]
    }

    private func makeClips(_ game: Game) async throws -> ClipExtractor {
        let extractor = ClipExtractor(backgroundTime: NoBackgroundTime(), unfinished: UnfinishedClips(defaults: defaults))
        XCTAssertTrue(extractor.start(game: game, context: context))
        let deadline = ContinuousClock.now + .seconds(180)
        while extractor.phase == .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(extractor.phase, .finished)
        return extractor
    }

    /// Mean brightness 0...255 of the frame at `seconds`.
    private func gray(of url: URL, at seconds: Double) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = 16, height = 9
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) { sum += Double(pixels[index]) }
        return sum / Double(width * height)
    }

    // MARK: Model

    func testNewGameStartsWithOnePartAndAddVideoAppendsTheNext() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 4, part2Seconds: 3)
        XCTAssertEqual(game.orderedParts.map(\.title), ["Part 1", "Part 2"])
        XCTAssertEqual(game.orderedParts.map(\.index), [0, 1])
        XCTAssertTrue(game.orderedParts.allSatisfy { $0.game === game })
        XCTAssertTrue(game.hasSeveralParts)
        XCTAssertEqual(game.durationSeconds, game.orderedParts[0].durationSeconds + game.orderedParts[1].durationSeconds, accuracy: 0.001)
        XCTAssertEqual(game.availableVideoBytes, game.orderedParts.reduce(0) { $0 + $1.videoFileSize })
        XCTAssertEqual(game.storageBytes, game.availableVideoBytes, "no clips yet")
        XCTAssertEqual(game.nextPartIndex, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Game>()), 1, "still one game")

        // The same video may be added twice (decision 0022): another copy, another part.
        let again = try await makeVideo(seconds: 2, gray: Self.part2Gray)
        try StorageManager.addPart(again, to: game, in: context)
        XCTAssertEqual(game.orderedParts.map(\.title), ["Part 1", "Part 2", "Part 3"])
        // Adding a part doesn't change the game's date.
        XCTAssertEqual(game.recordedAt, game.firstPart.recordedAt)
    }

    func testOneVideoGameHasOnePartAndNoPartLabels() {
        let game = Game(label: "", recordedAt: .now, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 9)
        context.insert(game)
        XCTAssertEqual(game.parts.count, 1)
        XCTAssertFalse(game.hasSeveralParts)
        XCTAssertEqual(game.durationSeconds, 60)
        XCTAssertEqual(game.firstPart.videoFilename, "x.mov")
        XCTAssertEqual(game.legacyVideoFilename, "x.mov")
    }

    func testMarksAndClipsSortByPartThenTime() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 4, part2Seconds: 3)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        let late1 = mark(3, in: one, of: game)
        let early2 = mark(1, in: two, of: game)
        let early1 = mark(0.5, in: one, of: game)
        XCTAssertEqual(game.pendingMarks.map(\.id), [early1.id, late1.id, early2.id])
        for (mark, start) in [(early2, 0.0), (late1, 2.0), (early1, 0.0)] {
            let clip = Clip(id: mark.id, filename: StorageManager.makeClipFilename(id: mark.id), startSeconds: start, endSeconds: start + 1, fileSize: 1)
            context.insert(clip)
            clip.game = game
            clip.part = mark.part
        }
        XCTAssertEqual(game.sortedClips.map(\.id), [early1.id, late1.id, early2.id])
    }

    // MARK: Clips

    func testClipsAreCutFromTheirOwnPartAndNeverCrossIntoAnother() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 12)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        let nearEnd = mark(19.5, in: one, of: game)   // window would run past Part 1's end
        let nearStart = mark(1, in: two, of: game)    // window would start before Part 2's start
        let sameTime1 = mark(10, in: one, of: game)
        let sameTime2 = mark(10, in: two, of: game)   // same tap time, other part: its own clip

        let extractor = try await makeClips(game)
        XCTAssertEqual(extractor.completed, 4)
        XCTAssertEqual(game.clips.count, 4, "one clip per mark, none skipped as a duplicate")
        XCTAssertEqual(Set(game.clips.map(\.id)), Set([nearEnd, nearStart, sameTime1, sameTime2].map(\.id)), "named after their marks")
        XCTAssertEqual(Set(game.clips.map(\.filename)).count, 4, "no two clips share a file")
        XCTAssertTrue(game.marks.allSatisfy(\.isExtracted))
        XCTAssertTrue(game.isProcessed)

        for clip in game.clips {
            let part = try XCTUnwrap(clip.part)
            XCTAssertTrue(part === game.marks.first { $0.id == clip.id }?.part, "the clip's part is its mark's")
            XCTAssertGreaterThanOrEqual(clip.startSeconds, 0)
            XCTAssertLessThanOrEqual(clip.endSeconds, part.durationSeconds + 0.001, "clamped to its own part")
            let level = try await gray(of: clip.fileURL, at: 0.5)
            let expected = Double(part === one ? Self.part1Gray : Self.part2Gray)
            XCTAssertEqual(level, expected, accuracy: 25, "cut from \(part.title)'s video")
        }
        let end = try XCTUnwrap(game.clips.first { $0.id == nearEnd.id })
        XCTAssertEqual(end.endSeconds, one.durationSeconds, accuracy: 0.001)
        let start = try XCTUnwrap(game.clips.first { $0.id == nearStart.id })
        XCTAssertEqual(start.startSeconds, 0)
        XCTAssertNotNil(one.processedAt)
        XCTAssertNotNil(two.processedAt)
        XCTAssertEqual(game.sortedClips.map { $0.part!.index }, [0, 0, 1, 1])
    }

    func testTrimStaysInsideItsOwnPart() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 12)
        let two = game.orderedParts[1]
        let tap = mark(6, in: two, of: game)
        _ = try await makeClips(game)
        let clip = try XCTUnwrap(game.clips.first { $0.id == tap.id })

        let session = TrimSession(clip: clip)
        XCTAssertTrue(session.canTrim)
        XCTAssertLessThanOrEqual(session.bounds.end, two.durationSeconds + 0.001, "the handles stop at Part 2's end")
        session.tearDown()

        do {
            try await ClipExtractor.trim(clip, to: ClipWindow(start: 4, end: two.durationSeconds + 2), context: context) { _ in }
            XCTFail("a window past the part's end must be refused")
        } catch ClipExportError.cannotTrim {}

        try await ClipExtractor.trim(clip, to: ClipWindow(start: 3, end: 9), context: context) { _ in }
        XCTAssertEqual(clip.startSeconds, 3)
        XCTAssertEqual(clip.endSeconds, 9)
        let duration = try await AVURLAsset(url: clip.fileURL).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.1)
        let level = try await gray(of: clip.fileURL, at: 0.5)
        XCTAssertEqual(level, Double(Self.part2Gray), accuracy: 25, "re-cut from Part 2")
    }

    func testMarkingIsPerPart() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 4, part2Seconds: 3)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        _ = mark(1, in: one, of: game)
        var clock: CFTimeInterval = 1_000
        let session = MarkingSession(game: game, part: two, context: context, clock: { clock })
        defer { session.tearDown() }
        XCTAssertEqual(session.duration, two.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(session.markCount, 0, "Part 1's mark isn't shown in Part 2")

        XCTAssertTrue(session.placeMark())
        clock += 1
        XCTAssertFalse(session.placeMark(), "the 2-second guard")
        clock += 1.5
        XCTAssertTrue(session.placeMark())
        XCTAssertEqual(session.markCount, 2)
        XCTAssertEqual(session.ticks.count, 2)
        XCTAssertEqual(two.marks.count, 2)
        XCTAssertEqual(one.marks.count, 1)
        game.marks.filter { $0.part === two }.forEach { track($0.id) }

        session.undoLastMark()
        XCTAssertEqual(session.markCount, 1)
        XCTAssertEqual(one.marks.count, 1, "Undo never touches another part")
        XCTAssertEqual(game.marks.count, 2)
    }

    // MARK: Resume

    func testResumeFinishesMarksInAnyPartWithoutDuplicates() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 20)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        for offset in [5.0, 15.0] { _ = mark(offset, in: one, of: game) }
        for offset in [5.0, 15.0] { _ = mark(offset, in: two, of: game) }
        let unfinished = UnfinishedClips(defaults: defaults)

        // Cut off after the first clip, as when iOS ends background time.
        let time = ExpiringBackgroundTime()
        let first = ClipExtractor(backgroundTime: time, unfinished: unfinished)
        XCTAssertTrue(first.start(game: game, context: context))
        let deadline = ContinuousClock.now + .seconds(120)
        while first.completed < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        time.expire()
        while first.phase == .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(first.phase, .interrupted)
        XCTAssertEqual(unfinished.gamesToFinish(from: [game]), [game], "\"Finishing your clips\" picks it up")

        let resumed = ClipExtractor(backgroundTime: NoBackgroundTime(), unfinished: unfinished)
        XCTAssertTrue(resumed.start(game: game, context: context))
        while resumed.phase == .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(resumed.phase, .finished)
        XCTAssertEqual(game.clips.count, 4, "no duplicates")
        XCTAssertEqual(Set(game.clips.map(\.id)), Set(game.marks.map(\.id)), "one clip per mark")
        XCTAssertEqual(game.clips.filter { $0.part === two }.count, 2)
        XCTAssertTrue(unfinished.gamesToFinish(from: [game]).isEmpty)
    }

    func testMarksInADeletedPartWaitAndAreNotResumed() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 4, part2Seconds: 3)
        let one = game.orderedParts[0]
        _ = mark(1, in: one, of: game)
        StorageManager.deleteGameVideo(game, in: context)
        XCTAssertTrue(game.extractableMarks.isEmpty)
        let unfinished = UnfinishedClips(defaults: defaults)
        unfinished.add(game.id)
        XCTAssertTrue(unfinished.gamesToFinish(from: [game]).isEmpty)
    }

    // MARK: Retention

    func testExpiryIsPerPartAndAnUnmarkedPartIsNeverAtStake() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 4)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        _ = mark(10, in: one, of: game)
        _ = try await makeClips(game)
        XCTAssertTrue(one.isProcessed)
        XCTAssertFalse(two.isProcessed, "never marked")
        XCTAssertNotNil(one.videoExpiresAt)
        XCTAssertNil(two.videoExpiresAt, "a part never processed never expires")
        XCTAssertEqual(game.processedAvailableParts.map(\.index), [0])

        // Launch cleanup 8 days later: only Part 1's video goes.
        StorageManager.performLaunchCleanup(in: context, now: .now.addingTimeInterval(8 * 24 * 60 * 60))
        XCTAssertFalse(one.isVideoAvailable)
        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.videoURL(for: one)))
        XCTAssertTrue(two.isVideoAvailable)
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.videoURL(for: two)))
        XCTAssertTrue(game.isVideoAvailable)
        XCTAssertEqual(game.clips.count, 1, "clips are kept")
    }

    func testPromptDeleteRemovesOnlyProcessedPartsAndKeepCoversLaterParts() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 4)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        _ = mark(10, in: one, of: game)
        _ = try await makeClips(game)

        StorageManager.deleteProcessedVideos(of: game, in: context)
        XCTAssertFalse(one.isVideoAvailable)
        XCTAssertTrue(two.isVideoAvailable, "not marked yet: kept")
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.videoURL(for: two)))

        // Keep is game-wide: it covers a part added afterwards.
        game.keepsVideo = true
        let third = try await makeVideo(seconds: 2, gray: Self.part2Gray)
        let added = try StorageManager.addPart(third, to: game, in: context)
        added.processedAt = .now.addingTimeInterval(-30 * 24 * 60 * 60)
        XCTAssertNil(added.videoExpiresAt)
        StorageManager.performLaunchCleanup(in: context)
        XCTAssertTrue(added.isVideoAvailable)

        // A part added to a game whose first video is gone can still be marked.
        XCTAssertFalse(one.isVideoAvailable)
        XCTAssertTrue(game.isVideoAvailable)
    }

    func testMissingFileMarksOnlyItsOwnPartUnavailable() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 3, part2Seconds: 3)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        StorageManager.removeFile(at: StorageManager.videoURL(for: two))
        StorageManager.performLaunchCleanup(in: context)
        XCTAssertTrue(one.isVideoAvailable)
        XCTAssertFalse(two.isVideoAvailable)
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.videoURL(for: one)), "nothing deleted by the check")
    }

    // MARK: Recovery

    func testAddedPartIsNotTakenForAnOrphan() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 3, part2Seconds: 3)
        await StorageManager.recoverRecordings(in: context)
        let games = try context.fetch(FetchDescriptor<Game>())
        let mine = Set(game.parts.map(\.videoFilename))
        let recoveredMine = games.filter { $0 !== game && $0.parts.contains { mine.contains($0.videoFilename) } }
        XCTAssertTrue(recoveredMine.isEmpty, "Part 2's file belongs to the game; it isn't recovered as a new one")
        XCTAssertEqual(game.parts.count, 2)
        // Any games recovered from unrelated files in the test host are left as they are.
    }

    func testInterruptedAddVideoComesBackAsItsOwnGame() async throws {
        // The file reached Games/ but the app died before the part was saved.
        let stray = try await makeVideo(seconds: 3, gray: Self.part2Gray)
        await StorageManager.recoverRecordings(in: context)
        let recovered = try context.fetch(FetchDescriptor<Game>()).filter { $0.firstPart.videoFilename == stray.filename }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered.first?.label.hasPrefix("Recovered") == true)
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.gameVideoURL(filename: stray.filename)), "footage kept")
    }

    // MARK: Deletion

    func testDeletingAClipDeletesItsOwnMarkOnly() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 20)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        let keep = mark(10, in: one, of: game)
        let gone = mark(10, in: two, of: game)
        _ = try await makeClips(game)
        let clip = try XCTUnwrap(game.clips.first { $0.id == gone.id })
        let files = [clip.fileURL, StorageManager.thumbnailURL(forClipID: clip.id)]

        StorageManager.deleteClip(clip, in: context)
        XCTAssertEqual(game.marks.map(\.id), [keep.id], "the same tap time in Part 1 is another mark")
        XCTAssertEqual(game.clips.map(\.id), [keep.id])
        for url in files { XCTAssertFalse(StorageManager.fileExists(at: url)) }
    }

    func testDeletingTheGameRemovesEveryPartsFilesAndNothingElse() async throws {
        let game = try await makeTwoPartGame(part1Seconds: 20, part2Seconds: 20)
        let (one, two) = (game.orderedParts[0], game.orderedParts[1])
        _ = mark(10, in: one, of: game)
        _ = mark(10, in: two, of: game)
        _ = try await makeClips(game)
        let neighbor = try await makeVideo(seconds: 2, gray: Self.part1Gray)
        let other = Game(label: "Other", recordedAt: .now, videoFilename: neighbor.filename, durationSeconds: neighbor.durationSeconds,
                         source: .imported, videoFileSize: neighbor.fileSize)
        context.insert(other)
        try context.save()

        var files = game.parts.map { StorageManager.videoURL(for: $0) }
        for clip in game.clips {
            _ = await ThumbnailGenerator.thumbnail(clipID: clip.id, clipURL: clip.fileURL, clipDuration: clip.window.duration)
            files += [clip.fileURL, StorageManager.thumbnailURL(forClipID: clip.id)]
        }
        XCTAssertTrue(files.allSatisfy(StorageManager.fileExists(at:)))

        StorageManager.deleteGame(game, in: context)
        for url in files { XCTAssertFalse(StorageManager.fileExists(at: url), "\(url.lastPathComponent) left behind") }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GamePart>()), 1, "only the other game's part is left")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Mark>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 0)
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.videoURL(for: other.firstPart)), "another game's video is untouched")
    }
}

/// Background time that never runs out.
@MainActor
private struct NoBackgroundTime: BackgroundTimeGranting {
    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(rawValue: 1)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {}
}

/// Background time that runs out when told to.
@MainActor
private final class ExpiringBackgroundTime: BackgroundTimeGranting {
    private var onExpiry: (@MainActor () -> Void)?

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        self.onExpiry = onExpiry
        return UIBackgroundTaskIdentifier(rawValue: 1)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {}

    func expire() { onExpiry?() }
}
