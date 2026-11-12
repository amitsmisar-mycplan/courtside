import SwiftData
import XCTest
@testable import Courtside

/// The schema as it was before player tags (decision 0030), to build an old store.
private enum BeforePlayers {
    @Model final class Game {
        var id: UUID
        var label: String
        var recordedAt: Date
        var source: GameSource
        var isProcessed: Bool
        var keepsVideo: Bool = false
        var opponent: String?
        var ourScore: Int?
        var theirScore: Int?
        var notes: String?
        var team: String?
        var tournament: String?
        @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
        @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]
        @Relationship(deleteRule: .cascade, inverse: \GamePart.game) var parts: [GamePart] = []
        var videoFilename: String
        var durationSeconds: Double
        var videoFileSize: Int64
        var isVideoAvailable: Bool
        var processedAt: Date?

        init(id: UUID) {
            self.id = id
            label = "Old game"
            recordedAt = .now
            source = .imported
            isProcessed = true
            videoFilename = "old.mov"
            durationSeconds = 600
            videoFileSize = 1
            isVideoAvailable = true
            opponent = "Hawks"
            marks = []
            clips = []
        }
    }

    @Model final class GamePart {
        var id: UUID
        var index: Int
        var videoFilename: String
        var durationSeconds: Double
        var videoFileSize: Int64
        var recordedAt: Date
        var isVideoAvailable: Bool
        var processedAt: Date?
        var momentsFoundAt: Date?
        var game: Game?
        @Relationship(deleteRule: .nullify, inverse: \Mark.part) var marks: [Mark]
        @Relationship(deleteRule: .nullify, inverse: \Clip.part) var clips: [Clip]
        @Relationship(deleteRule: .cascade, inverse: \SuggestedMoment.part) var suggestions: [SuggestedMoment] = []

        init(index: Int) {
            id = UUID()
            self.index = index
            videoFilename = "old-\(index).mov"
            durationSeconds = 600
            videoFileSize = 1
            recordedAt = .now
            isVideoAvailable = true
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
        var part: GamePart?

        init(offset: Double) {
            id = UUID()
            offsetSeconds = offset
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
        var aimTrackData: Data?
        var game: Game?
        var part: GamePart?

        init(mark: Double) {
            id = UUID()
            filename = "old-clip-\(Int(mark)).mov"
            startSeconds = mark - 10
            endSeconds = mark + 3
            createdAt = .now
            fileSize = 1
            markSeconds = mark
        }
    }

    @Model final class SuggestedMoment {
        var id: UUID
        var seconds: Double
        var score: Double
        var status: Courtside.SuggestedMoment.Status
        var sound: Courtside.SuggestedMoment.Sound
        var createdAt: Date
        var markID: UUID?
        var part: GamePart?

        init(seconds: Double) {
            id = UUID()
            self.seconds = seconds
            score = 4
            status = .pending
            sound = .cheering
            createdAt = .now
        }
    }
}

@MainActor
final class PlayerTagTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    /// The app's own settings, with the two player keys saved in setUp and put back in tearDown:
    /// a separate suite would leave a settings file behind in the app container.
    private let defaults = UserDefaults.standard
    private var savedSettings: [String: Any] = [:]
    private let settingKeys = [PlayerSettings.myPlayerKey, PlayerSettings.clipFilterKey]
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self, Player.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for key in settingKeys {
            savedSettings[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        // Runs whether the test passed or failed: nothing it made is left in the app container.
        for url in createdFiles { try? FileManager.default.removeItem(at: url) }
        for key in settingKeys {
            defaults.set(savedSettings[key], forKey: key)
        }
        container = nil
    }

    // MARK: Fixtures

    /// A game with two parts and a clip at each mark time (first half in Part 1, the rest in Part 2),
    /// each with a small stand-in file in the clips folder.
    private func makeGame(marks: [Double] = [30, 90, 150, 210]) throws -> Game {
        let game = Game(label: "", recordedAt: .now, videoFilename: "tag-test.mov", durationSeconds: 600,
                        source: .imported, videoFileSize: 1)
        context.insert(game)
        let parts = (0..<2).map { GamePart(index: $0, videoFilename: "tag-test-\($0).mov", durationSeconds: 300, videoFileSize: 1, recordedAt: .now) }
        for part in parts {
            context.insert(part)
            part.game = game
        }
        for (i, mark) in marks.enumerated() {
            let id = UUID()
            let filename = StorageManager.makeClipFilename(id: id)
            let url = StorageManager.clipURL(filename: filename)
            try Data("clip".utf8).write(to: url)
            createdFiles.append(url)
            let clip = Clip(id: id, filename: filename, startSeconds: mark - 10, endSeconds: mark + 3, fileSize: 4, markSeconds: mark)
            context.insert(clip)
            clip.game = game
            clip.part = parts[i < marks.count / 2 ? 0 : 1]
        }
        try context.save()
        return game
    }

    // MARK: Migration

    func testStoreFromBeforePlayersOpensWithEveryClipUntagged() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("players-migrate-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let gameID = UUID()
        do {
            let old = try ModelContainer(
                for: Schema([BeforePlayers.Game.self, BeforePlayers.GamePart.self, BeforePlayers.Mark.self,
                             BeforePlayers.Clip.self, BeforePlayers.SuggestedMoment.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = old.mainContext
            let game = BeforePlayers.Game(id: gameID)
            context.insert(game)
            for index in 0..<2 {
                let part = BeforePlayers.GamePart(index: index)
                context.insert(part)
                part.game = game
                let mark = BeforePlayers.Mark(offset: 100 + Double(index))
                context.insert(mark)
                mark.game = game
                mark.part = part
                let clip = BeforePlayers.Clip(mark: 100 + Double(index))
                context.insert(clip)
                clip.game = game
                clip.part = part
                let moment = BeforePlayers.SuggestedMoment(seconds: 200)
                context.insert(moment)
                moment.part = part
            }
            try context.save()
        }

        do {
            // Today's app: lightweight migration adds the Player model and the empty tag.
            let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self, Player.self,
                                               configurations: ModelConfiguration(url: storeURL))
            let context = container.mainContext
            let game = try XCTUnwrap(try context.fetch(FetchDescriptor<Game>()).first { $0.id == gameID })
            XCTAssertEqual(game.opponent, "Hawks")
            XCTAssertEqual(game.parts.count, 2)
            XCTAssertEqual(game.marks.count, 2)
            XCTAssertEqual(game.sortedClips.map(\.markSeconds), [100, 101])
            XCTAssertTrue(game.clips.allSatisfy { $0.player == nil }, "existing clips are untagged")
            XCTAssertEqual(game.parts.flatMap(\.suggestions).count, 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Player>()), 0)

            let sam = try XCTUnwrap(Player.add(name: "Sam", number: "7", in: context))
            Player.tag([try XCTUnwrap(game.sortedClips.last)], with: sam, in: context)
        }

        let reopened = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self, Player.self,
                                          configurations: ModelConfiguration(url: storeURL))
        let game = try XCTUnwrap(try reopened.mainContext.fetch(FetchDescriptor<Game>()).first)
        XCTAssertEqual(game.sortedClips.map { $0.player?.name }, [nil, "Sam"], "a tag in Part 2 survives reopening")
    }

    // MARK: Tagging

    func testTagRetagAndUntagClipsAcrossParts() throws {
        let game = try makeGame()
        let clips = game.sortedClips
        let sam = try XCTUnwrap(Player.add(name: "  Sam ", number: "#07", in: context))
        let ava = try XCTUnwrap(Player.add(name: "Ava", in: context))
        XCTAssertEqual(sam.name, "Sam")
        XCTAssertEqual(sam.number, "07")
        XCTAssertEqual(sam.shortLabel, "#07")
        XCTAssertNil(ava.number)
        XCTAssertNotEqual(sam.color, ava.color, "each new player gets the next unused color")
        XCTAssertNil(Player.add(name: "   ", in: context), "a name is required")

        // Several at once, across both parts (the Select mode's Tag Player).
        Player.tag([clips[1], clips[2]], with: sam, in: context)
        XCTAssertEqual(clips.map { $0.player?.name }, [nil, "Sam", "Sam", nil])
        XCTAssertEqual(Set(sam.clips.map(\.id)), [clips[1].id, clips[2].id])

        // One tag per clip: tagging again replaces it.
        Player.tag([clips[2]], with: ava, in: context)
        XCTAssertEqual(clips.map { $0.player?.name }, [nil, "Sam", "Ava", nil])
        XCTAssertEqual(sam.clips.map(\.id), [clips[1].id])

        Player.tag([clips[1]], with: nil, in: context)
        XCTAssertNil(clips[1].player)
        XCTAssertTrue(sam.clips.isEmpty)
    }

    // MARK: Filter

    func testFilterAllMyPlayerUntaggedAndAPlayer() throws {
        let game = try makeGame(marks: [30, 90, 150, 210, 270])
        let clips = game.sortedClips
        let sam = try XCTUnwrap(Player.add(name: "Sam", in: context))
        let ava = try XCTUnwrap(Player.add(name: "Ava", in: context))
        Player.tag([clips[0], clips[3]], with: sam, in: context)
        Player.tag([clips[1]], with: ava, in: context)

        func shown(_ filter: ClipFilter, my: UUID?) -> [Double?] {
            filter.apply(to: game.sortedClips, myPlayerID: my).map(\.markSeconds)
        }
        XCTAssertEqual(shown(.all, my: sam.id), [30, 90, 150, 210, 270])
        XCTAssertEqual(shown(.myPlayer, my: sam.id), [30, 210])
        XCTAssertEqual(shown(.myPlayer, my: ava.id), [90])
        XCTAssertEqual(shown(.untagged, my: sam.id), [150, 270])
        XCTAssertEqual(shown(.player(ava.id), my: sam.id), [90])
        XCTAssertEqual(shown(.player(UUID()), my: sam.id), [])

        // What the list shows when the remembered filter no longer applies.
        let ids: Set<UUID> = [sam.id, ava.id]
        XCTAssertEqual(ClipFilter.myPlayer.resolved(myPlayerID: sam.id, playerIDs: ids), .myPlayer)
        XCTAssertEqual(ClipFilter.myPlayer.resolved(myPlayerID: nil, playerIDs: ids), .all, "no My Player chosen")
        XCTAssertEqual(ClipFilter.myPlayer.resolved(myPlayerID: UUID(), playerIDs: ids), .all, "My Player was deleted")
        XCTAssertEqual(ClipFilter.player(ava.id).resolved(myPlayerID: nil, playerIDs: ids), .player(ava.id))
        XCTAssertEqual(ClipFilter.player(UUID()).resolved(myPlayerID: nil, playerIDs: ids), .all, "that player was deleted")
        XCTAssertEqual(ClipFilter.untagged.resolved(myPlayerID: nil, playerIDs: []), .untagged)
        XCTAssertEqual(ClipFilter.player(sam.id).resolved(myPlayerID: sam.id, playerIDs: ids), .myPlayer,
                       "a player who became My Player has no chip of their own")
    }

    // MARK: Deleting

    func testDeletingAPlayerUntagsTheirClipsAndKeepsClipsMarksAndFiles() throws {
        let game = try makeGame()
        let sam = try XCTUnwrap(Player.add(name: "Sam", in: context))
        let ava = try XCTUnwrap(Player.add(name: "Ava", in: context))
        Player.tag(Array(game.sortedClips.prefix(3)), with: sam, in: context)
        Player.tag([game.sortedClips[3]], with: ava, in: context)
        PlayerSettings.setMyPlayerID(sam.id, in: defaults)

        Player.delete(sam, in: context, settings: defaults)

        XCTAssertEqual(game.clips.count, 4, "no clip deleted")
        XCTAssertEqual(game.marks.count, 0, "the fixture has no marks; none appeared or vanished")
        XCTAssertEqual(game.sortedClips.map { $0.player?.name }, [nil, nil, nil, "Ava"])
        for clip in game.clips {
            XCTAssertTrue(FileManager.default.fileExists(atPath: clip.fileURL.path), "clip files untouched")
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Player>()).map(\.name), ["Ava"])
        XCTAssertNil(PlayerSettings.myPlayerID(in: defaults), "My Player cleared when it was deleted")

        // Reading back from a fresh context: the untagging was saved.
        let fresh = ModelContext(container)
        let clips = try fresh.fetch(FetchDescriptor<Clip>())
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips.filter { $0.player != nil }.count, 1)
    }

    func testDeletingClipsAndGamesLeavesPlayersAlone() throws {
        let game = try makeGame()
        let other = try makeGame(marks: [40, 100])
        let sam = try XCTUnwrap(Player.add(name: "Sam", in: context))
        Player.tag(game.clips + other.clips, with: sam, in: context)
        XCTAssertEqual(sam.clips.count, 6)

        StorageManager.deleteClip(try XCTUnwrap(game.sortedClips.first), in: context)
        XCTAssertEqual(sam.clips.count, 5)

        StorageManager.deleteGame(game, in: context)
        let players = try context.fetch(FetchDescriptor<Player>())
        XCTAssertEqual(players.map(\.name), ["Sam"], "the player stays")
        XCTAssertEqual(Set(sam.clips.map(\.id)), Set(other.clips.map(\.id)), "only the other game's clips remain tagged")
    }

    // MARK: Remembered settings

    func testFilterAndMyPlayerAreRememberedAcrossLaunches() throws {
        let id = UUID()
        XCTAssertEqual(PlayerSettings.clipFilter(in: defaults), .all, "default")
        XCTAssertNil(PlayerSettings.myPlayerID(in: defaults))

        PlayerSettings.setMyPlayerID(id, in: defaults)
        PlayerSettings.setClipFilter(.player(id), in: defaults)
        // A relaunch reads the stored values back; flush them first, as the app does on quit.
        defaults.synchronize()
        let relaunched = UserDefaults.standard
        XCTAssertEqual(PlayerSettings.myPlayerID(in: relaunched), id)
        XCTAssertEqual(PlayerSettings.clipFilter(in: relaunched), .player(id))

        for filter in [ClipFilter.all, .myPlayer, .untagged, .player(id)] {
            PlayerSettings.setClipFilter(filter, in: defaults)
            XCTAssertEqual(PlayerSettings.clipFilter(in: relaunched), filter)
            XCTAssertEqual(ClipFilter(rawValue: filter.rawValue), filter)
        }
        XCTAssertNil(ClipFilter(rawValue: "player:not-a-uuid"))
        PlayerSettings.setMyPlayerID(nil, in: defaults)
        XCTAssertNil(PlayerSettings.myPlayerID(in: relaunched), "None")

        // The views use @AppStorage with these keys; their stored form is a plain string.
        XCTAssertEqual(PlayerSettings.myPlayerKey, "myPlayerID")
        XCTAssertEqual(PlayerSettings.clipFilterKey, "clipListFilter")
    }
}
