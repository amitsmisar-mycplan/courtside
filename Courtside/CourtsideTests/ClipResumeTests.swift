import SwiftData
import UIKit
import XCTest
@testable import Courtside

/// Background time hands out tokens and runs out only when the test says so.
@MainActor
private final class FakeBackgroundTime: BackgroundTimeGranting {
    private var onExpiry: (@MainActor () -> Void)?
    private(set) var begun = 0
    private(set) var ended: [UIBackgroundTaskIdentifier] = []

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        self.onExpiry = onExpiry
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        ended.append(task)
    }

    /// What iOS does just before suspending the app.
    func expire() {
        onExpiry?()
    }
}

/// Clip-making stops cleanly when background time runs out and finishes the missing clips later,
/// never remaking or duplicating one (decision 0017). Real exports, in-memory store.
@MainActor
final class ClipResumeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var unfinished: UnfinishedClips { UnfinishedClips(defaults: defaults) }
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: Game.self, Mark.self, Clip.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        suiteName = "ClipResumeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A 60 s game video with a mark every 10 s from 5 s.
    private func makeGame(marks offsets: [Double] = [5, 15, 25, 35, 45, 55]) async throws -> Game {
        let id = UUID()
        let filename = StorageManager.makeGameVideoFilename(id: id, fileExtension: "mov")
        let url = StorageManager.gameVideoURL(filename: filename)
        try await TestMedia.makeVideo(at: url, seconds: 60, fps: 30, withTone: true)
        createdFiles.append(url)
        let game = Game(id: id, label: "Test", recordedAt: .now, videoFilename: filename,
                        durationSeconds: 60, source: .imported, videoFileSize: StorageManager.fileSize(at: url))
        context.insert(game)
        for offset in offsets {
            let mark = Mark(offsetSeconds: offset)
            context.insert(mark)
            mark.game = game
            let clipURL = StorageManager.clipURL(filename: StorageManager.makeClipFilename(id: mark.id))
            createdFiles += [clipURL, StorageManager.partialURL(for: clipURL), StorageManager.thumbnailURL(forClipID: mark.id)]
        }
        try context.save()
        return game
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// File identity: a re-export replaces the file, so its inode changes.
    private func identity(of url: URL) throws -> (Int, Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.systemFileNumber] as? Int) ?? -1, (attributes[.modificationDate] as? Date) ?? .distantPast)
    }

    private func partials(of game: Game) -> [URL] {
        game.marks.map { StorageManager.partialURL(for: StorageManager.clipURL(filename: StorageManager.makeClipFilename(id: $0.id))) }
            .filter(StorageManager.fileExists(at:))
    }

    func testBackgroundExpiryStopsCleanlyThenResumeMakesOnlyMissingClips() async throws {
        let game = try await makeGame()
        let videoURL = StorageManager.gameVideoURL(for: game)
        let videoSize = StorageManager.fileSize(at: videoURL)
        let time = FakeBackgroundTime()
        let extractor = ClipExtractor(backgroundTime: time, unfinished: unfinished)

        XCTAssertTrue(extractor.start(game: game, context: context))
        XCTAssertEqual(unfinished.gameIDs, [game.id], "listed while running, so a crash is resumed too")
        try await waitUntil { extractor.completed >= 1 }
        time.expire()
        XCTAssertEqual(time.ended, [UIBackgroundTaskIdentifier(rawValue: 1)], "background time is handed back inside the expiry handler")
        try await waitUntil { extractor.phase != .running }

        // Stopped cleanly: finished clips, marks, and the video are untouched; no partial file is left.
        XCTAssertEqual(extractor.phase, .interrupted)
        let made = game.clips
        XCTAssertGreaterThanOrEqual(made.count, 1)
        XCTAssertLessThan(made.count, 6, "the run must stop before the end for this test to mean anything")
        XCTAssertEqual(partials(of: game), [])
        XCTAssertEqual(StorageManager.fileSize(at: videoURL), videoSize)
        XCTAssertEqual(game.marks.count, 6)
        XCTAssertEqual(Set(game.marks.filter(\.isExtracted).map(\.id)), Set(made.map(\.id)))
        for clip in made { XCTAssertTrue(StorageManager.fileExists(at: clip.fileURL)) }
        XCTAssertEqual(time.ended.count, 1, "ended exactly once")
        XCTAssertEqual(unfinished.gameIDs, [game.id])
        XCTAssertEqual(unfinished.gamesToFinish(from: [game]), [game])
        let before = try Dictionary(uniqueKeysWithValues: made.map { ($0.id, try identity(of: $0.fileURL)) })

        // Next launch: a fresh extractor finishes only what's missing.
        let resumed = ClipExtractor(backgroundTime: FakeBackgroundTime(), unfinished: unfinished)
        XCTAssertTrue(resumed.start(game: game, context: context))
        XCTAssertEqual(resumed.total, 6 - made.count)
        try await waitUntil { resumed.phase != .running }

        XCTAssertEqual(resumed.phase, .finished)
        XCTAssertEqual(resumed.completed, 6 - made.count)
        XCTAssertEqual(game.clips.count, 6, "no duplicates")
        XCTAssertEqual(Set(game.clips.map(\.id)), Set(game.marks.map(\.id)), "one clip per mark")
        XCTAssertTrue(game.marks.allSatisfy(\.isExtracted))
        XCTAssertTrue(game.isProcessed)
        for (id, identity) in before {
            let clip = try XCTUnwrap(game.clips.first { $0.id == id })
            let now = try self.identity(of: clip.fileURL)
            XCTAssertEqual(now.0, identity.0, "finished clip was not remade")
            XCTAssertEqual(now.1, identity.1)
        }
        XCTAssertEqual(partials(of: game), [])
        XCTAssertEqual(unfinished.gameIDs, [])
    }

    func testExpiryDuringExportDeletesOnlyThatPartial() async throws {
        let game = try await makeGame(marks: [30])
        let time = FakeBackgroundTime()
        let extractor = ClipExtractor(backgroundTime: time, unfinished: unfinished)
        extractor.start(game: game, context: context)
        let partial = StorageManager.partialURL(for: StorageManager.clipURL(filename: StorageManager.makeClipFilename(id: game.marks[0].id)))
        try await waitUntil { StorageManager.fileExists(at: partial) || extractor.phase != .running }
        time.expire()
        XCTAssertFalse(StorageManager.fileExists(at: partial), "removed in the expiry handler, before iOS suspends")
        try await waitUntil { extractor.phase != .running }

        // Either the export was caught mid-way (nothing made) or had just landed (one clip, kept).
        XCTAssertEqual(partials(of: game), [])
        XCTAssertEqual(game.clips.count, game.marks.filter(\.isExtracted).count)
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.gameVideoURL(for: game)))
    }

    func testFinishedFileWithoutRecordIsAdoptedNotRemade() async throws {
        // The app was closed after a clip's file was finished but before it was recorded.
        let game = try await makeGame(marks: [20])
        let mark = game.marks[0]
        let url = StorageManager.clipURL(filename: StorageManager.makeClipFilename(id: mark.id))
        try await ClipExtractor.export(source: StorageManager.gameVideoURL(for: game), window: ClipWindow(start: 10, end: 23), to: url) { _ in }
        let before = try identity(of: url)

        let extractor = ClipExtractor(backgroundTime: FakeBackgroundTime(), unfinished: unfinished)
        extractor.start(game: game, context: context)
        try await waitUntil { extractor.phase != .running }

        XCTAssertEqual(extractor.completed, 1)
        XCTAssertEqual(game.clips.map(\.id), [mark.id])
        XCTAssertTrue(mark.isExtracted)
        let after = try identity(of: url)
        XCTAssertEqual(after.0, before.0, "adopted, not exported again")
        XCTAssertEqual(after.1, before.1)
    }

    func testExistingClipRecordIsNotDuplicated() async throws {
        // A clip for this tap is already recorded but its mark was left pending.
        let game = try await makeGame(marks: [20])
        let existing = Clip(filename: "existing.mov", startSeconds: 10, endSeconds: 23, fileSize: 1, markSeconds: 20)
        context.insert(existing)
        existing.game = game
        try context.save()

        let time = FakeBackgroundTime()
        let extractor = ClipExtractor(backgroundTime: time, unfinished: unfinished)
        extractor.start(game: game, context: context)
        try await waitUntil { extractor.phase != .running }

        XCTAssertEqual(game.clips.map(\.id), [existing.id])
        XCTAssertTrue(game.marks[0].isExtracted)
        XCTAssertEqual(time.ended.count, 1)
    }

    func testParentStopIsNotResumed() async throws {
        let game = try await makeGame(marks: [20, 40])
        let extractor = ClipExtractor(backgroundTime: FakeBackgroundTime(), unfinished: unfinished)
        extractor.start(game: game, context: context)
        extractor.cancel()
        try await waitUntil { extractor.phase != .running }

        XCTAssertEqual(extractor.phase, .cancelled)
        XCTAssertEqual(unfinished.gameIDs, [])
        XCTAssertEqual(partials(of: game), [])
        XCTAssertFalse(game.pendingMarks.isEmpty, "the rest wait on the game page")
    }

    func testStoppingWhilePausedClearsTheResume() async throws {
        let game = try await makeGame(marks: [20, 40])
        let time = FakeBackgroundTime()
        let extractor = ClipExtractor(backgroundTime: time, unfinished: unfinished)
        extractor.start(game: game, context: context)
        time.expire()
        try await waitUntil { extractor.phase != .running }
        XCTAssertEqual(extractor.phase, .interrupted)

        extractor.cancel()
        XCTAssertEqual(extractor.phase, .cancelled)
        XCTAssertEqual(unfinished.gameIDs, [])
    }

    func testOnlyOneBatchRunsAtATime() async throws {
        let first = try await makeGame(marks: [20])
        let second = try await makeGame(marks: [20])
        let a = ClipExtractor(backgroundTime: FakeBackgroundTime(), unfinished: unfinished)
        let b = ClipExtractor(backgroundTime: FakeBackgroundTime(), unfinished: unfinished)
        XCTAssertTrue(a.start(game: first, context: context))
        XCTAssertFalse(b.start(game: second, context: context), "exports are serial, never parallel")
        try await waitUntil { a.phase != .running }
        XCTAssertTrue(b.start(game: second, context: context))
        try await waitUntil { b.phase != .running }
        XCTAssertEqual(first.clips.count + second.clips.count, 2)
    }

    func testGamesToFinishDropsGamesWithNothingLeft() async throws {
        let waiting = try await makeGame(marks: [20])
        let done = try await makeGame(marks: [])
        let videoGone = try await makeGame(marks: [20])
        videoGone.isVideoAvailable = false
        let deleted = UUID()
        for id in [waiting.id, done.id, videoGone.id, deleted] { unfinished.add(id) }

        XCTAssertEqual(unfinished.gamesToFinish(from: [waiting, done, videoGone]), [waiting])
        XCTAssertEqual(unfinished.gameIDs, [waiting.id])
    }
}
