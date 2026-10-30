import SwiftData
import XCTest
@testable import Courtside

/// Game details (opponent, score, notes), how a game is titled, that details survive a relaunch,
/// and that deleting a game removes only the files it owns.
@MainActor
final class GameLibraryTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
    }

    private func makeGame(label: String = "") -> Game {
        Game(label: label, recordedAt: .now, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
    }

    // MARK: Title and score

    func testTitlePrefersOpponentThenNameThenUntitled() {
        let game = makeGame()
        XCTAssertEqual(game.displayTitle, "Untitled game")
        game.label = "Tournament day 2"
        XCTAssertEqual(game.displayTitle, "Tournament day 2")
        game.opponent = "Lakers"
        XCTAssertEqual(game.displayTitle, "vs Lakers")
        game.opponent = "   "
        XCTAssertEqual(game.displayTitle, "Tournament day 2", "a blank opponent doesn't count")
        game.label = "  "
        XCTAssertEqual(game.displayTitle, "Untitled game")
    }

    func testScoreText() {
        let game = makeGame()
        XCTAssertNil(game.scoreText)
        game.ourScore = 54
        XCTAssertEqual(game.scoreText, "54–?")
        game.theirScore = 48
        XCTAssertEqual(game.scoreText, "54–48")
        game.ourScore = nil
        XCTAssertEqual(game.scoreText, "?–48")
    }

    // MARK: Persistence

    func testDetailsSurviveRelaunch() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let id: UUID
        do {
            let container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
            let game = makeGame()
            game.opponent = "Lakers"
            game.ourScore = 54
            game.theirScore = 48
            game.notes = "Great second half"
            game.recordedAt = date
            container.mainContext.insert(game)
            try container.mainContext.save()
            id = game.id
        }

        // A fresh container on the same file stands in for relaunching the app.
        let reopened = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let games = try reopened.mainContext.fetch(FetchDescriptor<Game>())
        let game = try XCTUnwrap(games.first { $0.id == id })
        XCTAssertEqual(game.opponent, "Lakers")
        XCTAssertEqual(game.ourScore, 54)
        XCTAssertEqual(game.theirScore, 48)
        XCTAssertEqual(game.notes, "Great second half")
        XCTAssertEqual(game.recordedAt, date)
        XCTAssertEqual(game.displayTitle, "vs Lakers")
    }

    // MARK: Deletion

    /// A game with a video file and one clip (with a slow-mo render and a thumbnail) on disk.
    private func makeGameWithFiles(in context: ModelContext) throws -> (Game, [URL]) {
        let gameID = UUID()
        let videoFilename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: "mov")
        let clipID = UUID()
        let clipFilename = StorageManager.makeClipFilename(id: clipID)
        let slowMoFilename = StorageManager.makeSlowMoFilename(clipID: clipID, speed: .half)
        let urls = [
            StorageManager.gameVideoURL(filename: videoFilename),
            StorageManager.clipURL(filename: clipFilename),
            StorageManager.clipURL(filename: slowMoFilename),
            StorageManager.thumbnailURL(forClipID: clipID),
        ]
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        createdFiles += urls

        let game = Game(id: gameID, label: "", recordedAt: .now, videoFilename: videoFilename,
                        durationSeconds: 60, source: .imported, videoFileSize: 1)
        context.insert(game)
        let clip = Clip(id: clipID, filename: clipFilename, startSeconds: 0, endSeconds: 13, fileSize: 1)
        clip.slowMoFilename = slowMoFilename
        clip.slowMoSpeed = 0.5
        context.insert(clip)
        clip.game = game
        let mark = Mark(offsetSeconds: 10)
        context.insert(mark)
        mark.game = game
        try context.save()
        return (game, urls)
    }

    func testDeletingAGameRemovesOnlyItsOwnFilesAndRecords() throws {
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let (doomed, doomedFiles) = try makeGameWithFiles(in: context)
        let (kept, keptFiles) = try makeGameWithFiles(in: context)

        StorageManager.deleteGame(doomed, in: context)

        for url in doomedFiles {
            XCTAssertFalse(StorageManager.fileExists(at: url), url.lastPathComponent)
        }
        for url in keptFiles {
            XCTAssertTrue(StorageManager.fileExists(at: url), url.lastPathComponent)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Game>()).map(\.id), [kept.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 1, "the deleted game's clip goes with it")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Mark>()), 1)
        XCTAssertEqual(kept.clips.count, 1)
    }
}
