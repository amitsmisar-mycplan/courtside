import SwiftData
import XCTest
@testable import Courtside

/// The schema as it was before parts (decision 0022): one video per game, to build an old store.
private enum BeforeParts {
    @Model final class Game {
        var id: UUID
        var label: String
        var recordedAt: Date
        var videoFilename: String
        var durationSeconds: Double
        var source: GameSource
        var isProcessed: Bool
        var videoFileSize: Int64
        var isVideoAvailable: Bool
        var processedAt: Date?
        var keepsVideo: Bool = false
        var opponent: String?
        var ourScore: Int?
        var theirScore: Int?
        var notes: String?
        var team: String?
        var tournament: String?
        @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
        @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]

        init(id: UUID, filename: String, isVideoAvailable: Bool, processedAt: Date?) {
            self.id = id
            label = "Old game"
            recordedAt = Date(timeIntervalSince1970: 1_790_000_000)
            videoFilename = filename
            durationSeconds = 1_234.5
            source = .imported
            isProcessed = true
            videoFileSize = 987_654_321
            self.isVideoAvailable = isVideoAvailable
            self.processedAt = processedAt
            keepsVideo = false
            opponent = "Lakers"
            ourScore = 54
            theirScore = 48
            team = "Eagles"
            tournament = "Fall Classic"
            marks = []
            clips = []
        }
    }

    @Model final class Mark {
        var id: UUID
        var offsetSeconds: Double
        var createdAt: Date
        var isExtracted: Bool
        var game: Game?

        init(offsetSeconds: Double, isExtracted: Bool) {
            id = UUID()
            self.offsetSeconds = offsetSeconds
            createdAt = .now
            self.isExtracted = isExtracted
        }
    }

    @Model final class Clip {
        var id: UUID
        var filename: String
        var startSeconds: Double
        var endSeconds: Double
        var createdAt: Date
        var fileSize: Int64
        var markSeconds: Double?
        var slowMoFilename: String?
        var slowMoSpeed: Double?
        var slowMoStartSeconds: Double?
        var slowMoEndSeconds: Double?
        var slowMoFileSize: Int64?
        var game: Game?

        init(id: UUID, mark: Double) {
            self.id = id
            filename = "\(id.uuidString).mov"
            startSeconds = mark - 10
            endSeconds = mark + 3
            createdAt = .now
            fileSize = 12_345
            markSeconds = mark
        }
    }
}

/// Every game from before parts opens with one part, "Part 1", holding its video, marks and clips,
/// with nothing changed or lost (decision 0022).
final class PartsMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory.appending(path: "parts-\(UUID().uuidString)/default.store")
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private struct OldIDs {
        let game: UUID
        let deletedVideoGame: UUID
        let marks: [UUID]
        let clip: UUID
        let processedAt: Date
    }

    /// An old-format store: a processed game with three marks (two made into clips, one pending)
    /// and a slow-mo render, plus a game whose video was already deleted.
    @MainActor private func makeOldStore() throws -> OldIDs {
        let old = try ModelContainer(
            for: Schema([BeforeParts.Game.self, BeforeParts.Mark.self, BeforeParts.Clip.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = old.mainContext
        let processedAt = Date(timeIntervalSince1970: 1_790_100_000)
        let game = BeforeParts.Game(id: UUID(), filename: "old-game.mp4", isVideoAvailable: true, processedAt: processedAt)
        context.insert(game)
        var markIDs: [UUID] = []
        for (offset, extracted) in [(20.0, true), (600.0, true), (1_200.0, false)] {
            let mark = BeforeParts.Mark(offsetSeconds: offset, isExtracted: extracted)
            context.insert(mark)
            mark.game = game
            markIDs.append(mark.id)
        }
        let clip = BeforeParts.Clip(id: markIDs[0], mark: 20)
        context.insert(clip)
        clip.game = game
        clip.slowMoFilename = "\(clip.id.uuidString)-slowmo-0.5x.mov"
        clip.slowMoSpeed = 0.5
        let second = BeforeParts.Clip(id: markIDs[1], mark: 600)
        context.insert(second)
        second.game = game

        let gone = BeforeParts.Game(id: UUID(), filename: "deleted.mov", isVideoAvailable: false, processedAt: processedAt)
        context.insert(gone)
        try context.save()
        return OldIDs(game: game.id, deletedVideoGame: gone.id, marks: markIDs, clip: clip.id, processedAt: processedAt)
    }

    @MainActor func testOldGameOpensWithOnePartAndEverythingIntact() throws {
        let ids = try makeOldStore()

        // Opened by today's app: lightweight migration, then the Part 1 step.
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let context = container.mainContext
        XCTAssertEqual(StorageManager.migrateToParts(in: context), 2)

        let games = try context.fetch(FetchDescriptor<Game>())
        XCTAssertEqual(games.count, 2, "no game lost")
        let game = try XCTUnwrap(games.first { $0.id == ids.game })
        XCTAssertEqual(game.parts.count, 1)
        let part = game.firstPart
        XCTAssertEqual(part.title, "Part 1")
        XCTAssertEqual(part.videoFilename, "old-game.mp4")
        XCTAssertEqual(part.durationSeconds, 1_234.5)
        XCTAssertEqual(part.videoFileSize, 987_654_321)
        XCTAssertEqual(part.recordedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(part.isVideoAvailable)
        XCTAssertEqual(part.processedAt, ids.processedAt, "the 7-day clock carries over")
        XCTAssertTrue(part.game === game)

        // Totals read the same as before.
        XCTAssertEqual(game.durationSeconds, 1_234.5)
        XCTAssertEqual(game.availableVideoBytes, 987_654_321)
        XCTAssertTrue(game.isVideoAvailable)
        XCTAssertEqual(game.videoExpiresAt, ids.processedAt.addingTimeInterval(Game.videoRetention))

        // Marks and clips: all there, all in Part 1, times unchanged.
        XCTAssertEqual(Set(game.marks.map(\.id)), Set(ids.marks))
        XCTAssertEqual(game.marks.sorted { $0.offsetSeconds < $1.offsetSeconds }.map(\.offsetSeconds), [20, 600, 1_200])
        XCTAssertTrue(game.marks.allSatisfy { $0.part === part })
        XCTAssertEqual(game.pendingMarks.map(\.offsetSeconds), [1_200])
        XCTAssertEqual(game.extractableMarks.count, 1)
        XCTAssertEqual(game.clips.count, 2)
        XCTAssertTrue(game.clips.allSatisfy { $0.part === part })
        let clip = try XCTUnwrap(game.clips.first { $0.id == ids.clip })
        XCTAssertEqual(clip.startSeconds, 10)
        XCTAssertEqual(clip.endSeconds, 23)
        XCTAssertEqual(clip.markSeconds, 20)
        XCTAssertEqual(clip.filename, "\(ids.clip.uuidString).mov")
        XCTAssertEqual(clip.slowMoSpeed, 0.5)
        XCTAssertEqual(part.marks.count, 3)
        XCTAssertEqual(part.clips.count, 2)

        // Everything else on the game is untouched.
        XCTAssertEqual(game.displayTitle, "Eagles vs Lakers")
        XCTAssertEqual(game.scoreText, "54–48")
        XCTAssertEqual(game.tournament, "Fall Classic")
        XCTAssertTrue(game.isProcessed)
        XCTAssertEqual(game.legacyVideoFilename, "old-game.mp4", "old fields are kept")
        XCTAssertEqual(game.legacyDurationSeconds, 1_234.5)

        // A game whose video was already deleted stays that way.
        let gone = try XCTUnwrap(games.first { $0.id == ids.deletedVideoGame })
        XCTAssertFalse(gone.firstPart.isVideoAvailable)
        XCTAssertFalse(gone.isVideoAvailable)
        XCTAssertNil(gone.videoExpiresAt)
    }

    @MainActor func testMigrationRunsOnceAndSurvivesReopening() throws {
        let ids = try makeOldStore()
        do {
            let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
            XCTAssertEqual(StorageManager.migrateToParts(in: container.mainContext), 2)
            XCTAssertEqual(StorageManager.migrateToParts(in: container.mainContext), 0, "safe to run again")
        }
        let reopened = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let context = reopened.mainContext
        XCTAssertEqual(StorageManager.migrateToParts(in: context), 0, "nothing left to do on the next launch")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GamePart>()), 2)
        let game = try XCTUnwrap(try context.fetch(FetchDescriptor<Game>()).first { $0.id == ids.game })
        XCTAssertEqual(game.parts.count, 1)
        XCTAssertEqual(game.clips.count, 2)
        XCTAssertTrue(game.clips.allSatisfy { $0.part === game.firstPart })
    }

    @MainActor func testStoreIsBackedUpOnceBeforeParts() throws {
        _ = try makeOldStore()
        let backup = storeURL.deletingLastPathComponent().appending(path: "StoreBackup-0022")
        StorageManager.backUpStoreBeforeParts(storeURL: storeURL)
        let copied = try FileManager.default.contentsOfDirectory(atPath: backup.path)
        XCTAssertTrue(copied.contains("default.store"))
        let size = StorageManager.fileSize(at: backup.appending(path: "default.store"))
        XCTAssertGreaterThan(size, 0)

        // Never overwritten: a later launch leaves the first copy alone.
        let marker = backup.appending(path: "default.store")
        let before = try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        StorageManager.backUpStoreBeforeParts(storeURL: storeURL)
        let after = try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}
