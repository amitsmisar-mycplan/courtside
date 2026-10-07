import SwiftData
import XCTest
@testable import Courtside

/// A force-quit or crash mid-game must never lose footage.
@MainActor
final class RecordingRecoveryTests: XCTestCase {
    private var container: ModelContainer!
    private var created: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        created.forEach(StorageManager.removeFile(at:))
    }

    private func video(named filename: String, seconds: Int = 3) async throws -> URL {
        let url = StorageManager.gameVideoURL(filename: filename)
        try await TestMedia.makeVideo(at: url, seconds: seconds, fps: 30, withTone: false)
        created.append(url)
        return url
    }

    func testZeroLengthRecordingGetsItsRealDuration() async throws {
        let filename = "\(UUID().uuidString).mov"
        _ = try await video(named: filename, seconds: 4)
        let game = Game(label: "Interrupted", recordedAt: .now, videoFilename: filename, durationSeconds: 0, source: .recorded, videoFileSize: 0)
        container.mainContext.insert(game)

        await StorageManager.recoverRecordings(in: container.mainContext)

        XCTAssertEqual(game.durationSeconds, 4, accuracy: 0.1)
        XCTAssertGreaterThan(game.videoFileSize, 0)
    }

    func testOrphanedVideoBecomesAGame() async throws {
        let filename = "\(UUID().uuidString).mov"
        _ = try await video(named: filename, seconds: 3)

        await StorageManager.recoverRecordings(in: container.mainContext)

        let games = try container.mainContext.fetch(FetchDescriptor<Game>()).filter { $0.videoFilename == filename }
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.durationSeconds ?? 0, 3, accuracy: 0.1)
        XCTAssertTrue(games.first?.label.hasPrefix("Recovered") == true)
    }

    func testUnplayableAndPartialFilesAreLeftAlone() async throws {
        let junk = StorageManager.gameVideoURL(filename: "\(UUID().uuidString).mov")
        try Data(repeating: 0, count: 1024).write(to: junk)
        created.append(junk)
        let partialName = "\(UUID().uuidString).partial.mov"
        _ = try await video(named: partialName)

        await StorageManager.recoverRecordings(in: container.mainContext)

        let filenames = try container.mainContext.fetch(FetchDescriptor<Game>()).map(\.videoFilename)
        XCTAssertFalse(filenames.contains(junk.lastPathComponent))
        XCTAssertFalse(filenames.contains(partialName))
        XCTAssertTrue(StorageManager.fileExists(at: junk), "never delete footage, even if unreadable")
    }
}
