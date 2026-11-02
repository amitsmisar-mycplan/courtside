import SwiftData
import XCTest
@testable import Courtside

/// The schema as it was before team and tournament (decision 0019), to build an old store.
private enum BeforeLabels {
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
        @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
        @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]

        init(id: UUID, opponent: String) {
            self.id = id
            label = "Old game"
            recordedAt = Date(timeIntervalSince1970: 1_790_000_000)
            videoFilename = "old.mov"
            durationSeconds = 60
            source = .imported
            isProcessed = true
            videoFileSize = 1
            isVideoAvailable = true
            self.opponent = opponent
            ourScore = 54
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

        init(offsetSeconds: Double) {
            id = UUID()
            self.offsetSeconds = offsetSeconds
            createdAt = .now
            isExtracted = true
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

        init() {
            id = UUID()
            filename = "old-clip.mov"
            startSeconds = 10
            endSeconds = 23
            createdAt = .now
            fileSize = 1
            markSeconds = 20
        }
    }
}

final class GameLabelMigrationTests: XCTestCase {
    @MainActor
    func testGameFromBeforeLabelsOpensWithEmptyTeamAndTournament() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("labels-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }
        let id = UUID()
        do {
            let old = try ModelContainer(
                for: Schema([BeforeLabels.Game.self, BeforeLabels.Mark.self, BeforeLabels.Clip.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let game = BeforeLabels.Game(id: id, opponent: "Lakers")
            old.mainContext.insert(game)
            let mark = BeforeLabels.Mark(offsetSeconds: 20)
            old.mainContext.insert(mark)
            mark.game = game
            let clip = BeforeLabels.Clip()
            old.mainContext.insert(clip)
            clip.game = game
            try old.mainContext.save()
        }

        // Opened by today's app: lightweight migration adds the two empty fields.
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let games = try container.mainContext.fetch(FetchDescriptor<Game>())
        let game = try XCTUnwrap(games.first { $0.id == id })
        XCTAssertNil(game.team)
        XCTAssertNil(game.tournament)
        XCTAssertEqual(game.opponent, "Lakers")
        XCTAssertEqual(game.ourScore, 54)
        XCTAssertEqual(game.marks.count, 1)
        XCTAssertEqual(game.clips.count, 1)
        XCTAssertEqual(game.displayTitle, "vs Lakers", "today's fallback")
        XCTAssertNil(GameLabel.forExport(game: game, mode: .openAndClose)?.lines.first { $0.contains("Eagles") })

        game.team = "Eagles"
        game.tournament = "Fall Classic"
        try container.mainContext.save()
        XCTAssertEqual(game.displayTitle, "Eagles vs Lakers")
    }
}
