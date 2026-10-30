import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Trimming re-cuts the clip from the full game video through `ClipExtractor`, replaces its file
/// in place, survives a relaunch, and never exports while the edges are only being dragged.
@MainActor
final class ClipTrimTests: XCTestCase {
    private var createdFiles: [URL] = []
    private var storeURL: URL!

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).store")
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
    }

    /// A 40 s game video and the default clip around a tap at `mark`.
    private func makeGameAndClip(mark: Double, markSeconds: Double?? = .none, in context: ModelContext) async throws -> Clip {
        let gameID = UUID()
        let videoFilename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: "mov")
        let videoURL = StorageManager.gameVideoURL(filename: videoFilename)
        try await TestMedia.makeVideo(at: videoURL, seconds: 40, fps: 10, withTone: false)
        createdFiles.append(videoURL)
        let game = Game(id: gameID, label: "", recordedAt: .now, videoFilename: videoFilename, durationSeconds: 40,
                        source: .recorded, videoFileSize: StorageManager.fileSize(at: videoURL))
        context.insert(game)

        let window = ClipWindow.defaultTrim(mark: mark, gameDuration: 40)
        let clipID = UUID()
        let filename = StorageManager.makeClipFilename(id: clipID)
        let clipURL = StorageManager.clipURL(filename: filename)
        try await ClipExtractor.export(source: videoURL, window: window, to: clipURL) { _ in }
        createdFiles += [clipURL, StorageManager.thumbnailURL(forClipID: clipID)]
        let clip = Clip(id: clipID, filename: filename, startSeconds: window.start, endSeconds: window.end,
                        fileSize: StorageManager.fileSize(at: clipURL), markSeconds: markSeconds ?? mark)
        context.insert(clip)
        clip.game = game
        try context.save()
        return clip
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    // MARK: Acceptance

    func testTrimSaveRelaunchKeepsTheNewRange() async throws {
        let clipID: UUID
        let filename: String
        do {
            let container = try makeContainer()
            let clip = try await makeGameAndClip(mark: 20, in: container.mainContext)
            XCTAssertEqual(clip.window, ClipWindow(start: 10, end: 23))
            clipID = clip.id
            filename = clip.filename
            let oldSize = clip.fileSize

            var progress: [Double] = []
            try await ClipExtractor.trim(clip, to: ClipWindow(start: 4, end: 30), context: container.mainContext) { progress.append($0) }

            XCTAssertEqual(progress.last, 1, "progress reaches the end")
            XCTAssertNotEqual(clip.fileSize, oldSize)
            let trimmed = try await duration(of: clip.fileURL)
            XCTAssertEqual(trimmed, 26, accuracy: 0.2)
        }

        // A fresh container on the same store stands in for relaunching the app.
        let reopened = try makeContainer()
        let clip = try XCTUnwrap(try reopened.mainContext.fetch(FetchDescriptor<Clip>()).first { $0.id == clipID })
        XCTAssertEqual(clip.window, ClipWindow(start: 4, end: 30))
        XCTAssertEqual(clip.markSeconds, 20)
        XCTAssertEqual(clip.secondsBeforeMark, 16)
        XCTAssertEqual(clip.secondsAfterMark, 10)
        XCTAssertEqual(clip.filename, filename, "same file, replaced in place")
    }

    func testOldClipFileIsReplacedNotLeftBehind() async throws {
        let container = try makeContainer()
        let clip = try await makeGameAndClip(mark: 20, in: container.mainContext)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: StorageManager.clipsDirectory.path))

        try await ClipExtractor.trim(clip, to: ClipWindow(start: 15, end: 25), context: container.mainContext) { _ in }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: StorageManager.clipsDirectory.path))
        XCTAssertEqual(after, before, "no new file, no leftover .partial file")
        let trimmed = try await duration(of: clip.fileURL)
        XCTAssertEqual(trimmed, 10, accuracy: 0.2)
    }

    func testTrimReachingPastBothEndsOfTheVideoClampsCleanly() async throws {
        let container = try makeContainer()
        // Tap 4 s in: 30 s before would be -26.
        let early = try await makeGameAndClip(mark: 4, in: container.mainContext)
        let session = TrimSession(clip: early)
        defer { session.tearDown() }
        XCTAssertEqual(session.bounds, ClipWindow(start: 0, end: 19))
        session.drag(.start, to: -50)
        session.drag(.end, to: 999)
        session.endDrag()
        XCTAssertEqual(session.window, ClipWindow(start: 0, end: 19))
        let saved = await session.save(context: container.mainContext)
        XCTAssertTrue(saved)
        XCTAssertEqual(early.window, ClipWindow(start: 0, end: 19))
        let trimmed = try await duration(of: early.fileURL)
        XCTAssertEqual(trimmed, 19, accuracy: 0.2)

        // Tap 2 s before the end: 15 s after would pass the end of the video.
        let late = try await makeGameAndClip(mark: 38, in: container.mainContext)
        let lateSession = TrimSession(clip: late)
        defer { lateSession.tearDown() }
        XCTAssertEqual(lateSession.bounds, ClipWindow(start: 8, end: 40))
        lateSession.drag(.end, to: 100)
        XCTAssertEqual(lateSession.window.end, 40)
    }

    // MARK: Editor behaviour

    func testDraggingNeverExports() async throws {
        let container = try makeContainer()
        let clip = try await makeGameAndClip(mark: 20, in: container.mainContext)
        let file = clip.fileURL
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let session = TrimSession(clip: clip)
        defer { session.tearDown() }

        for second in stride(from: 9.0, through: 15, by: 0.5) { session.drag(.start, to: second) }
        session.endDrag()
        for second in stride(from: 24.0, through: 32, by: 0.5) { session.drag(.end, to: second) }
        session.endDrag()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(session.window, ClipWindow(start: 15, end: 32))
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(clip.window, ClipWindow(start: 10, end: 23), "nothing saved")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: StorageManager.partialURL(for: file).path))
    }

    func testResetRestoresTenBeforeThreeAfter() async throws {
        let container = try makeContainer()
        let clip = try await makeGameAndClip(mark: 20, in: container.mainContext)
        let session = TrimSession(clip: clip)
        defer { session.tearDown() }
        session.drag(.start, to: 2)
        session.drag(.end, to: 33)
        XCTAssertFalse(session.isDefault)
        session.resetToDefault()
        XCTAssertEqual(session.window, ClipWindow(start: 10, end: 23))
        XCTAssertTrue(session.isDefault)
        XCTAssertFalse(session.canSave, "back where it started: nothing to save")
    }

    func testOlderClipWithoutStoredTapGetsItOnFirstTrim() async throws {
        let container = try makeContainer()
        // Made before the tap was stored: assumed 3 s before the end.
        let clip = try await makeGameAndClip(mark: 20, markSeconds: .some(nil), in: container.mainContext)
        XCTAssertNil(clip.markSeconds)
        XCTAssertEqual(clip.markTime, 20)
        try await ClipExtractor.trim(clip, to: ClipWindow(start: 12, end: 26), context: container.mainContext) { _ in }
        XCTAssertEqual(clip.markSeconds, 20, "the tap is kept when the edges move")
    }

    func testNoTrimWhenTheFullVideoIsGone() async throws {
        let container = try makeContainer()
        let clip = try await makeGameAndClip(mark: 20, in: container.mainContext)
        let game = try XCTUnwrap(clip.game)
        StorageManager.deleteGameVideo(game, in: container.mainContext)

        let session = TrimSession(clip: clip)
        defer { session.tearDown() }
        XCTAssertFalse(session.canTrim)
        XCTAssertNotNil(session.unavailableReason)
        session.drag(.start, to: 5)
        XCTAssertEqual(session.window, clip.window, "handles don't move")
        let saved = await session.save(context: container.mainContext)
        XCTAssertFalse(saved)

        do {
            try await ClipExtractor.trim(clip, to: ClipWindow(start: 15, end: 25), context: container.mainContext) { _ in }
            XCTFail("trim without the source must throw")
        } catch ClipExportError.sourceUnavailable {}
        XCTAssertTrue(StorageManager.fileExists(at: clip.fileURL), "the clip itself is kept")
    }
}
