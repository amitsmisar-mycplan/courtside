import SwiftData
import XCTest
@testable import Courtside

/// Slow-mo file and record lifecycle against real files in Documents/ and an in-memory store.
@MainActor
final class SlowMoLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: Game.self, Mark.self, Clip.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
    }

    /// A 10 s, 60 fps game video and a clip [2, 8] cut from it, with the tap at 6 s.
    private func makeGameAndClip() async throws -> (Game, Clip) {
        let gameID = UUID()
        let videoFilename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: "mov")
        let videoURL = StorageManager.gameVideoURL(filename: videoFilename)
        try await TestMedia.makeVideo(at: videoURL, seconds: 10, fps: 60, withTone: true)
        createdFiles.append(videoURL)

        let game = Game(id: gameID, label: "Test", recordedAt: .now, videoFilename: videoFilename,
                        durationSeconds: 10, source: .imported, videoFileSize: StorageManager.fileSize(at: videoURL))
        context.insert(game)

        let clipID = UUID()
        let clipFilename = StorageManager.makeClipFilename(id: clipID)
        let clipURL = StorageManager.clipURL(filename: clipFilename)
        try await ClipExtractor.export(source: videoURL, window: ClipWindow(start: 2, end: 8), to: clipURL) { _ in }
        createdFiles.append(clipURL)
        createdFiles.append(contentsOf: SlowMoSpeed.allCases.map {
            StorageManager.clipURL(filename: StorageManager.makeSlowMoFilename(clipID: clipID, speed: $0))
        })

        let clip = Clip(id: clipID, filename: clipFilename, startSeconds: 2, endSeconds: 8,
                        fileSize: StorageManager.fileSize(at: clipURL), markSeconds: 6)
        context.insert(clip)
        clip.game = game
        try context.save()
        return (game, clip)
    }

    func testMarkPositionInClip() {
        let stored = Clip(filename: "a.mov", startSeconds: 100, endSeconds: 113, fileSize: 1, markSeconds: 108)
        XCTAssertEqual(stored.markInClip, 8)
        // Clips from before markSeconds existed: assume the default 3 s post-roll.
        let legacy = Clip(filename: "b.mov", startSeconds: 100, endSeconds: 113, fileSize: 1)
        XCTAssertEqual(legacy.markInClip, 10)
    }

    func testRenderStoresFieldsAndCountsStorage() async throws {
        let (game, clip) = try await makeGameAndClip()
        let segment = SlowMotion.defaultSegment(markInClip: clip.markInClip, clipDuration: clip.window.duration)
        XCTAssertEqual(segment, SlowMoSegment(start: 2, end: 5.5))

        try await ClipExtractor.renderSlowMo(of: clip, segment: segment, speed: .quarter, context: context) { _ in }

        XCTAssertEqual(clip.slowMoFilename, "\(clip.id.uuidString)-slowmo-0.25.mov")
        XCTAssertEqual(clip.slowMoSpeed, 0.25)
        XCTAssertEqual(clip.slowMoStartSeconds, 2)
        XCTAssertEqual(clip.slowMoEndSeconds, 5.5)
        XCTAssertTrue(StorageManager.fileExists(at: try XCTUnwrap(clip.slowMoURL)))
        XCTAssertGreaterThan(clip.slowMoFileSize ?? 0, 0)
        XCTAssertEqual(game.clipsStorageBytes, clip.fileSize + (clip.slowMoFileSize ?? 0))
        XCTAssertTrue(StorageManager.fileExists(at: clip.fileURL), "original clip untouched")
    }

    func testReRenderAtOtherSpeedReplacesOldFile() async throws {
        let (_, clip) = try await makeGameAndClip()
        let segment = SlowMoSegment(start: 2, end: 5.5)
        try await ClipExtractor.renderSlowMo(of: clip, segment: segment, speed: .half, context: context) { _ in }
        let halfURL = try XCTUnwrap(clip.slowMoURL)

        try await ClipExtractor.renderSlowMo(of: clip, segment: segment, speed: .quarter, context: context) { _ in }
        let quarterURL = try XCTUnwrap(clip.slowMoURL)

        XCTAssertNotEqual(halfURL, quarterURL)
        XCTAssertFalse(StorageManager.fileExists(at: halfURL), "old render must not be orphaned")
        XCTAssertTrue(StorageManager.fileExists(at: quarterURL))
    }

    func testDeleteSlowMoOnlyKeepsClip() async throws {
        let (_, clip) = try await makeGameAndClip()
        try await ClipExtractor.renderSlowMo(of: clip, segment: SlowMoSegment(start: 2, end: 5.5), speed: .half, context: context) { _ in }
        let slowURL = try XCTUnwrap(clip.slowMoURL)

        StorageManager.deleteSlowMo(of: clip, in: context)

        XCTAssertFalse(StorageManager.fileExists(at: slowURL))
        XCTAssertNil(clip.slowMoFilename)
        XCTAssertNil(clip.slowMoFileSize)
        XCTAssertTrue(StorageManager.fileExists(at: clip.fileURL))
    }

    func testDeletingClipRemovesBothFiles() async throws {
        let (_, clip) = try await makeGameAndClip()
        try await ClipExtractor.renderSlowMo(of: clip, segment: SlowMoSegment(start: 2, end: 5.5), speed: .half, context: context) { _ in }
        let (clipURL, slowURL) = (clip.fileURL, try XCTUnwrap(clip.slowMoURL))

        StorageManager.deleteClip(clip, in: context)

        XCTAssertFalse(StorageManager.fileExists(at: clipURL))
        XCTAssertFalse(StorageManager.fileExists(at: slowURL))
    }

    func testNudgeRemovesStaleSlowMo() async throws {
        let (_, clip) = try await makeGameAndClip()
        try await ClipExtractor.renderSlowMo(of: clip, segment: SlowMoSegment(start: 2, end: 5.5), speed: .half, context: context) { _ in }
        let slowURL = try XCTUnwrap(clip.slowMoURL)

        try await ClipExtractor.nudge(clip, startBy: -1, endBy: 0, context: context)

        XCTAssertEqual(clip.startSeconds, 1)
        XCTAssertFalse(StorageManager.fileExists(at: slowURL))
        XCTAssertNil(clip.slowMoFilename)
        XCTAssertEqual(clip.markInClip, 5, "mark stays on the same game moment after a nudge")
    }
}
