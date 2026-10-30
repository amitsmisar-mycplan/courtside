import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// A video that can't be played must say so, not sit on a black screen that looks paused.
@MainActor
final class PlaybackFailureTests: XCTestCase {
    private var container: ModelContainer!
    private var files: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        container = nil
    }

    /// A file named like a video that holds no video at all.
    private func makeCorruptVideo() throws -> String {
        let filename = "corrupt-\(UUID().uuidString).mov"
        let url = StorageManager.gameVideoURL(filename: filename)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        files.append(url)
        return filename
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testMarkingSessionReportsFailureAndRefusesMarks() async throws {
        let game = Game(
            label: "Corrupt",
            recordedAt: .now,
            videoFilename: try makeCorruptVideo(),
            durationSeconds: 60,
            source: .imported,
            videoFileSize: 4096
        )
        container.mainContext.insert(game)
        let session = MarkingSession(game: game, context: container.mainContext)
        defer { session.tearDown() }
        session.player.play()

        await waitUntil { session.playbackFailed }
        XCTAssertTrue(session.playbackFailed)
        XCTAssertFalse(session.placeMark())
        XCTAssertEqual(game.marks.count, 0)
        // The footage is never removed because it failed to play.
        XCTAssertTrue(StorageManager.fileExists(at: StorageManager.gameVideoURL(for: game)))
    }

    func testLoopingClipPlayerReportsFailureAndRecoversOnReload() async throws {
        let player = LoopingClipPlayer()
        player.load(StorageManager.gameVideoURL(filename: try makeCorruptVideo()))
        await waitUntil { player.playbackFailed }
        XCTAssertTrue(player.playbackFailed)

        let good = FileManager.default.temporaryDirectory.appendingPathComponent("good-\(UUID().uuidString).mov")
        files.append(good)
        try await TestMedia.makeVideo(at: good, seconds: 2, fps: 30, withTone: false)
        player.load(good)
        XCTAssertFalse(player.playbackFailed)
        player.pause()
    }
}
