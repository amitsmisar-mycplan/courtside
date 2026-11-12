import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// The schema as it was before aim points (decision 0028), to build an old store.
private enum BeforeAim {
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
            durationSeconds = 60
            videoFileSize = 1
            isVideoAvailable = true
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
        var game: Game?
        @Relationship(deleteRule: .nullify, inverse: \Mark.part) var marks: [Mark]
        @Relationship(deleteRule: .nullify, inverse: \Clip.part) var clips: [Clip]

        init() {
            id = UUID()
            index = 0
            videoFilename = "old.mov"
            durationSeconds = 60
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

        init() {
            id = UUID()
            offsetSeconds = 20
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
        var part: GamePart?

        init(id: UUID) {
            self.id = id
            filename = "old-clip.mov"
            startSeconds = 10
            endSeconds = 23
            createdAt = .now
            fileSize = 1
            markSeconds = 20
        }
    }
}

/// Aim points for Vertical exports (decision 0028): the glide math, storage and migration, trim
/// re-mapping, the editor's session, and a real export whose crop moves between points.
@MainActor
final class AimKeyframesTests: XCTestCase {
    private static let hd = CGSize(width: 1920, height: 1080)
    private static let uhd = CGSize(width: 3840, height: 2160)
    private var files: [URL] = []
    private var savedZoom: Any?

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        LabelledExportCache.shared.removeAll()
        savedZoom = UserDefaults.standard.object(forKey: VerticalZoomSettings.lastZoomKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedZoom, forKey: VerticalZoomSettings.lastZoomKey)
        LabelledExportCache.shared.removeAll()
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func key(_ time: Double, _ x: Double) -> AimPath.Key {
        AimPath.Key(time: time, center: CGPoint(x: x, y: 0.5))
    }

    // MARK: Glide math

    func testOnePointIsExactlyTheStaticAim() {
        let path = AimPath(keys: [key(4, 0.3)])
        XCTAssertTrue(path.isStatic)
        let motion = path.motion(zoom: 1, videoSize: Self.uhd)
        let still = VerticalFraming(zoom: 1, center: CGPoint(x: 0.3, y: 0.5)).clamped(videoSize: Self.uhd)
        for time in [0.0, 4, 9.5] {
            XCTAssertEqual(motion.framing(at: time).foreground(videoSize: Self.uhd), still.foreground(videoSize: Self.uhd))
        }
        // The plan folds a single point into the framing: the same plan as today's single aim.
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        let pointed = ExportPlan(source: url, format: .vertical, label: nil, framing: VerticalFraming(zoom: 1), aim: path)
        let today = ExportPlan(source: url, format: .vertical, label: nil, framing: VerticalFraming(zoom: 1, center: CGPoint(x: 0.3, y: 0.5)))
        XCTAssertNil(pointed.aimPath)
        XCTAssertEqual(pointed.verticalFraming, today.verticalFraming)
        // Points that never move are static too, and Original ignores aim.
        XCTAssertNil(ExportPlan(source: url, format: .vertical, label: nil, framing: VerticalFraming(zoom: 1),
                                aim: AimPath(keys: [key(0, 0.3), key(5, 0.3)])).aimPath)
        XCTAssertNil(ExportPlan(source: url, format: .original, label: nil, framing: VerticalFraming(zoom: 1),
                                aim: AimPath(keys: [key(0, 0.2), key(5, 0.8)])).aimPath)
        XCTAssertNil(ExportPlan(source: url, format: .vertical, label: nil, framing: nil,
                                aim: AimPath(keys: [key(0, 0.2), key(5, 0.8)])).aimPath, "portrait clips aren't framed")
    }

    func testEaseIsSlowAtTheEndsAndHitsEachPoint() {
        XCTAssertEqual(AimPath.ease(0), 0)
        XCTAssertEqual(AimPath.ease(1), 1)
        XCTAssertEqual(AimPath.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertLessThan(AimPath.ease(0.1), 0.05, "starts slowly")
        XCTAssertGreaterThan(AimPath.ease(0.9), 0.95, "arrives slowly")
        let motion = AimPath(keys: [key(0, 0.2), key(10, 0.8), key(20, 0.4)]).motion(zoom: 1, videoSize: Self.uhd)
        XCTAssertEqual(motion.center(at: 10).x, 0.8, accuracy: 1e-9, "on time and on target")
        XCTAssertEqual(motion.center(at: 20).x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(motion.center(at: 5).x, 0.5, accuracy: 1e-9, "halfway at half time")
        XCTAssertLessThan(motion.center(at: 1).x - 0.2, 0.6 * 0.1, "slower than linear at the start")
        // Moving the other way after a point: no overshoot past it.
        for t in stride(from: 0.0, through: 20, by: 0.1) {
            XCTAssertLessThanOrEqual(motion.center(at: t).x, 0.8 + 1e-9)
            XCTAssertGreaterThanOrEqual(motion.center(at: t).x, 0.2 - 1e-9)
        }
    }

    func testHoldsBeforeTheFirstAndAfterTheLastPoint() {
        let motion = AimPath(keys: [key(3, 0.3), key(8, 0.7)]).motion(zoom: 1, videoSize: Self.uhd)
        for t in [0.0, 1, 2.99, 3] { XCTAssertEqual(motion.center(at: t).x, 0.3, accuracy: 1e-9, "t \(t)") }
        for t in [8.0, 9, 13] { XCTAssertEqual(motion.center(at: t).x, 0.7, accuracy: 1e-9, "t \(t)") }
    }

    func testPanSpeedNeverExceedsTheCap() {
        let window = VerticalFraming.windowSize(zoom: 1, videoSize: Self.uhd).width / Self.uhd.width
        // Far apart in place, close in time: the cap must bite.
        let path = AimPath(keys: [key(0, 0), key(0.5, 1), key(1, 0), key(4, 1), key(10, 0.5)])
        let motion = path.motion(zoom: 1, videoSize: Self.uhd)
        let step = 1.0 / 240
        var fastest = 0.0
        for t in stride(from: -1, through: 11, by: step) {
            let speed = abs(motion.center(at: t + step).x - motion.center(at: t).x) / step / window
            fastest = max(fastest, speed)
        }
        XCTAssertLessThanOrEqual(fastest, AimPath.maxSpeed * 1.001, "window widths per second")
        XCTAssertGreaterThan(fastest, AimPath.maxSpeed * 0.95, "the close points are capped right at the limit")
        // It falls short instead of arriving late: 0.5 s allows a third of a window.
        let reached = motion.center(at: 0.5).x - motion.center(at: 0).x
        XCTAssertEqual(reached, AimPath.maxSpeed * 0.5 / AimPath.easePeak * window, accuracy: 1e-9)
        // With time to spare it arrives exactly.
        XCTAssertEqual(motion.center(at: 10).x, 0.5, accuracy: 1e-9)
    }

    func testAimsAreClampedInsideTheVideoAtTheExportZoom() {
        let half = VerticalFraming.windowSize(zoom: 1, videoSize: Self.uhd).width / Self.uhd.width / 2
        let motion = AimPath(keys: [key(0, -1), key(5, 2)]).motion(zoom: 1, videoSize: Self.uhd)
        XCTAssertEqual(motion.center(at: 0).x, half, accuracy: 1e-9)
        XCTAssertEqual(motion.center(at: 5).x, 1 - half, accuracy: 1e-9)
        for t in stride(from: 0.0, through: 5, by: 0.25) {
            let window = motion.framing(at: t).window(videoSize: Self.uhd)
            XCTAssertGreaterThanOrEqual(window.minX, -1e-9)
            XCTAssertLessThanOrEqual(window.maxX, 1 + 1e-9)
        }
        // The 1.5× upscale cap still holds the zoom; at zoom 0 there's nothing to aim.
        XCTAssertEqual(AimPath(keys: [key(0, 0.1), key(5, 0.9)]).motion(zoom: 1, videoSize: Self.hd).zoom,
                       VerticalFraming.maxZoom(videoSize: Self.hd), accuracy: 1e-9)
        let flat = AimPath(keys: [key(0, 0.1), key(5, 0.9)]).motion(zoom: 0, videoSize: Self.hd)
        XCTAssertEqual(flat.center(at: 2.5).x, 0.5, accuracy: 1e-9)
    }

    func testCacheKeyIncludesMovingAim() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "aim-key-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        files.append(url)
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: nil, date: .now)
        let id = UUID()
        func cacheKey(_ aim: AimPath?) -> LabelledExportCache.Key {
            .init(clipID: id, source: .init(url), format: .vertical, label: label, quality: .hd1080, framing: VerticalFraming(zoom: 0.6), aim: aim)
        }
        XCTAssertEqual(cacheKey(AimPath(keys: [key(0, 0.2), key(3, 0.8)])), cacheKey(AimPath(keys: [key(0.001, 0.2), key(3, 0.8000001)])))
        XCTAssertNotEqual(cacheKey(AimPath(keys: [key(0, 0.2), key(3, 0.8)])), cacheKey(AimPath(keys: [key(0, 0.2), key(4, 0.8)])))
        XCTAssertNotEqual(cacheKey(nil), cacheKey(AimPath(keys: [key(0, 0.2), key(3, 0.8)])))
    }

    // MARK: Timeline and trims

    func testTimelineMapsGameTimeThroughSlowMo() {
        let plain = AimTimeline(clipStart: 100)
        XCTAssertEqual(plain.fileTime(104), 4)
        XCTAssertEqual(plain.gameTime(4), 104)
        // Clip time 2...4 plays at 0.5×: 4 s in the file.
        let slow = AimTimeline(clipStart: 100, slowMo: (.half, SlowMoSegment(start: 2, end: 4)))
        XCTAssertEqual(slow.fileTime(101), 1, accuracy: 1e-9, "before the slow part")
        XCTAssertEqual(slow.fileTime(103), 4, accuracy: 1e-9, "inside: stretched")
        XCTAssertEqual(slow.fileTime(104), 6, accuracy: 1e-9)
        XCTAssertEqual(slow.fileTime(110), 12, accuracy: 1e-9, "after: shifted by the extra 2 s")
        for game in stride(from: 100.0, through: 113, by: 0.37) {
            XCTAssertEqual(slow.gameTime(slow.fileTime(game)), game, accuracy: 1e-9)
        }
    }

    func testTrimKeepsMomentsAndMovesOutsidePointsToTheEdges() throws {
        let track = AimTrack(points: [
            AimPoint(time: 10, x: 0.1), AimPoint(time: 12, x: 0.2), AimPoint(time: 15, x: 0.5),
            AimPoint(time: 19, x: 0.8), AimPoint(time: 22, x: 0.9),
        ])
        // Shorter on both sides: inside points stay; the nearest outside one moves to each edge.
        let shorter = try XCTUnwrap(track.fitted(to: ClipWindow(start: 13, end: 20)))
        XCTAssertEqual(shorter.points, [AimPoint(time: 13, x: 0.2), AimPoint(time: 15, x: 0.5),
                                        AimPoint(time: 19, x: 0.8), AimPoint(time: 20, x: 0.9)])
        // Longer: nothing moves.
        XCTAssertEqual(track.fitted(to: ClipWindow(start: 5, end: 30))?.points, track.points)
        // All points before the window: one point at its start with the last aim.
        XCTAssertEqual(track.fitted(to: ClipWindow(start: 25, end: 30))?.points, [AimPoint(time: 25, x: 0.9)])
        // A point exactly on an edge isn't duplicated.
        XCTAssertEqual(track.fitted(to: ClipWindow(start: 12, end: 19))?.points.map(\.time), [12, 15, 19])
        XCTAssertLessThanOrEqual(shorter.points.count, AimTrack.manualLimit)
    }

    func testTrimRemapsStoredPoints() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("aim-trim-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let context = container.mainContext
        let gameID = UUID()
        let videoFilename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: "mov")
        let videoURL = StorageManager.gameVideoURL(filename: videoFilename)
        try await TestMedia.makeVideo(at: videoURL, seconds: 30, fps: 10, withTone: false)
        let game = Game(id: gameID, label: "", recordedAt: .now, videoFilename: videoFilename, durationSeconds: 30,
                        source: .recorded, videoFileSize: StorageManager.fileSize(at: videoURL))
        context.insert(game)
        let clipID = UUID()
        let filename = StorageManager.makeClipFilename(id: clipID)
        let clipURL = StorageManager.clipURL(filename: filename)
        files += [videoURL, clipURL, StorageManager.thumbnailURL(forClipID: clipID)]
        try await ClipExtractor.export(source: videoURL, window: ClipWindow(start: 10, end: 23), to: clipURL) { _ in }
        let clip = Clip(id: clipID, filename: filename, startSeconds: 10, endSeconds: 23, fileSize: 1, markSeconds: 20)
        context.insert(clip)
        clip.game = game
        clip.part = game.orderedParts.first
        clip.aimTrack = AimTrack(points: [AimPoint(time: 11, x: 0.2), AimPoint(time: 16, x: 0.5), AimPoint(time: 22, x: 0.8)])
        try context.save()

        try await ClipExtractor.trim(clip, to: ClipWindow(start: 13, end: 21), context: context) { _ in }
        XCTAssertEqual(clip.aimTrack?.points, [AimPoint(time: 13, x: 0.2), AimPoint(time: 16, x: 0.5), AimPoint(time: 21, x: 0.8)])

        // A clip without points stays without points.
        clip.aimTrack = nil
        try await ClipExtractor.trim(clip, to: ClipWindow(start: 12, end: 22), context: context) { _ in }
        XCTAssertNil(clip.aimTrackData)
    }

    // MARK: Storage

    func testOldClipsOpenWithNoPointsAndPointsSurviveARelaunch() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("aim-migrate-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let clipID = UUID()
        do {
            let old = try ModelContainer(
                for: Schema([BeforeAim.Game.self, BeforeAim.GamePart.self, BeforeAim.Mark.self, BeforeAim.Clip.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let game = BeforeAim.Game(id: UUID())
            old.mainContext.insert(game)
            let part = BeforeAim.GamePart()
            old.mainContext.insert(part)
            part.game = game
            let clip = BeforeAim.Clip(id: clipID)
            old.mainContext.insert(clip)
            clip.game = game
            clip.part = part
            try old.mainContext.save()
        }

        let points = [AimPoint(time: 11, x: 0.25), AimPoint(time: 18, x: 0.75, y: 0.4)]
        do {
            // Today's app: lightweight migration adds the empty field; the clip is otherwise unchanged.
            let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
            let clip = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<Clip>()).first { $0.id == clipID })
            XCTAssertNil(clip.aimTrack)
            XCTAssertEqual(clip.window, ClipWindow(start: 10, end: 23))
            XCTAssertEqual(clip.markSeconds, 20)
            XCTAssertNotNil(clip.game)
            clip.aimTrack = AimTrack(points: points)
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(url: storeURL))
        let context = reopened.mainContext
        let clip = try XCTUnwrap(try context.fetch(FetchDescriptor<Clip>()).first { $0.id == clipID })
        XCTAssertEqual(clip.aimTrack?.points, points)
        XCTAssertEqual(clip.aimTrack?.origin, .manual)

        // The points live on the clip's own record: deleting the clip removes them with it.
        StorageManager.deleteClip(clip, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Clip>()).isEmpty)
    }

    func testUnreadableOrEmptyDataMeansNoPoints() {
        XCTAssertNil(AimTrack.decode(Data("nonsense".utf8)))
        XCTAssertNil(AimTrack.decode(AimTrack(points: []).encoded()!))
        let unsorted = AimTrack(points: [AimPoint(time: 5, x: 0.1), AimPoint(time: 1, x: 0.9)], origin: .automatic)
        let decoded = AimTrack.decode(unsorted.encoded()!)
        XCTAssertEqual(decoded?.points.map(\.time), [1, 5])
        XCTAssertEqual(decoded?.origin, .automatic, "a tracker's points are marked as such")
    }

    // MARK: The editor's session

    func testNewClipStartsWithOneCenteredPointAndAddsMore() async throws {
        UserDefaults.standard.set(0.6, forKey: VerticalZoomSettings.lastZoomKey)
        var saved: [AimTrack?] = []
        let session = ClipExportSession(clipID: UUID(), source: try await banded(seconds: 6), timeline: AimTimeline(clipStart: 100),
                                        saveAim: { saved.append($0) }, photos: Photos())
        await session.load()
        XCTAssertEqual(session.aimKeys, [key(0, 0.5)], "one point, centered: today's export")
        XCTAssertEqual(session.preview.currentTime, 3, accuracy: 0.01, "opens on the middle, as before")
        XCTAssertTrue(session.canAddPoint)
        XCTAssertEqual(session.selectedPoint, 0, "the only point aims the whole clip")

        // Dragging with one point moves it (the whole clip), wherever the playhead is.
        session.moveWindow(by: CGSize(width: -0.1, height: 0))
        session.endMove()
        XCTAssertEqual(session.aimKeys.count, 1)
        XCTAssertEqual(session.aimKeys[0].center.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(saved.last??.points, [AimPoint(time: 100, x: session.aimKeys[0].center.x)], "saved in game-video seconds")

        // Add a second point here, then aim it.
        session.addPoint()
        XCTAssertEqual(session.aimKeys.map(\.time), [0, 3])
        XCTAssertTrue(session.canDeletePoint)
        session.moveWindow(by: CGSize(width: 0.3, height: 0))
        session.endMove()
        XCTAssertEqual(session.aimKeys[1].center.x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(saved.last??.points.map(\.time), [100, 103])

        // Between points a drag is a draft until added; scrubbing drops it.
        session.seek(to: 5)
        XCTAssertFalse(session.isOnPoint)
        session.moveWindow(by: CGSize(width: -0.2, height: 0))
        XCTAssertNotNil(session.draft)
        XCTAssertEqual(session.aimKeys.count, 2, "not a point yet")
        session.seek(to: 5.5)
        XCTAssertNil(session.draft)
        session.moveWindow(by: CGSize(width: -0.2, height: 0))
        let draft = try XCTUnwrap(session.draft)
        session.addPoint()
        XCTAssertNil(session.draft)
        XCTAssertEqual(session.aimKeys.last?.time ?? 0, 5.5, accuracy: 0.0001)
        XCTAssertEqual(session.aimKeys.last?.center.x ?? 0, draft.x, accuracy: 0.0001)

        // The window between points is the export's own math.
        session.seek(to: 1.5)
        let expected = AimPath(keys: session.aimKeys).motion(zoom: 0.6, videoSize: Self.hd).framing(at: 1.5).window(videoSize: Self.hd)
        XCTAssertEqual(session.framingWindow, expected)
        let plan = session.plan(for: .vertical)
        XCTAssertEqual(plan.aimPath?.keys, session.aimKeys)

        // Up to 5 points.
        session.seek(to: 1); session.addPoint()
        session.seek(to: 4.3); session.addPoint()
        XCTAssertEqual(session.aimKeys.count, AimTrack.manualLimit)
        session.seek(to: 2)
        XCTAssertFalse(session.canAddPoint)
        XCTAssertTrue(session.isAtPointLimit)

        // Tap a point to go to it; delete it.
        session.selectPoint(1)
        XCTAssertEqual(session.preview.currentTime, 1, accuracy: 0.0001)
        session.deletePoint()
        XCTAssertEqual(session.aimKeys.map(\.time), [0, 3, 4.3, 5.5])
        // Dragging a mark in time stays between its neighbors.
        session.movePoint(1, to: 10)
        XCTAssertEqual(session.aimKeys[1].time, 4.3 - ClipExportSession.pointTolerance, accuracy: 0.0001)
        session.endMove()
        XCTAssertEqual(saved.last??.points.count, 4)
        session.close()
    }

    func testStoredPointsLoadOnTheSlowMoTimelineAndSaveBack() async throws {
        var saved: AimTrack?
        let timeline = AimTimeline(clipStart: 50, slowMo: (.half, SlowMoSegment(start: 1, end: 2)))
        let stored = AimTrack(points: [AimPoint(time: 50.5, x: 0.3), AimPoint(time: 51.5, x: 0.7)])
        let session = ClipExportSession(clipID: UUID(), source: try await banded(seconds: 4), aimTrack: stored, timeline: timeline,
                                        saveAim: { saved = $0 }, photos: Photos())
        await session.load()
        XCTAssertEqual(session.aimKeys.map(\.time), [0.5, 2], "1.5 s into the clip is 2 s into the slow-mo file")
        XCTAssertEqual(session.preview.currentTime, 0.5, accuracy: 0.01, "opens on the first point")
        session.moveWindow(by: CGSize(width: 0.05, height: 0))
        session.endMove()
        XCTAssertEqual(saved?.points.map(\.time), [50.5, 51.5])
        // Deleting back to one centered point stores nothing, the same as never aiming.
        session.selectPoint(1)
        session.deletePoint()
        session.moveWindow(by: CGSize(width: 0.5 - session.aimKeys[0].center.x, height: 0))
        session.endMove()
        XCTAssertNil(saved)
        session.close()
    }

    // MARK: Real export

    func testThreePointExportGlidesTheCrop() async throws {
        let source = try await banded(seconds: 6, fps: 30)
        let zoom = VerticalFraming.maxZoom(videoSize: Self.hd)
        let path = AimPath(keys: [key(0.5, 0), key(3, 1), key(5, 0.5)])
        let output = try await export(source, framing: VerticalFraming(zoom: zoom), aim: path)

        let asset = AVURLAsset(url: output)
        let outputDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(outputDuration, 6, accuracy: 0.1)
        let size = try await SlowMoComposer.displaySize(of: output)
        XCTAssertEqual(size, ExportFormat.verticalRenderSize)

        // Darker rows show bands further left. Left at the start, right at 3 s, back to the middle.
        var means: [Double: Double] = [:]
        for t in [0.2, 1.0, 1.75, 2.5, 3.5, 5.5] {
            means[t] = try await DecodedFrame(of: output, at: t).meanGray(row: 960)
        }
        XCTAssertLessThan(means[0.2]!, means[1.0]!)
        XCTAssertLessThan(means[1.0]!, means[1.75]!, "gliding right")
        XCTAssertLessThan(means[1.75]!, means[2.5]!)
        XCTAssertGreaterThan(means[3.5]!, means[5.5]!, "back toward the middle")
        XCTAssertGreaterThan(means[5.5]!, means[0.2]!)

        // Each frame shows the bands the shared math puts there.
        let motion = path.motion(zoom: zoom, videoSize: Self.hd)
        let sourceFrame = try await DecodedFrame(of: source, at: 1)
        let levels = (0..<BandedVideo.bands).map { band in
            sourceFrame.gray(x: Int((Double(band) + 0.5) / Double(BandedVideo.bands) * Double(sourceFrame.width)), y: sourceFrame.height / 2)
        }
        for t in [0.2, 1.75, 3.5] {
            let frame = try await DecodedFrame(of: output, at: t)
            let foreground = motion.framing(at: t).foreground(videoSize: Self.hd)
            let bandWidth = Self.hd.width / CGFloat(BandedVideo.bands)
            var checked = 0
            for x in stride(from: 10, to: 1070, by: 20) {
                let sourceX = (CGFloat(x) - foreground.minX) / foreground.width * Self.hd.width
                let band = Int(sourceX / bandWidth)
                let offset = sourceX / bandWidth - CGFloat(band)
                // Band centers only (edges blend in the encoder), and a frame-time's slack.
                guard band >= 0, band < BandedVideo.bands, offset > 0.3, offset < 0.7 else { continue }
                XCTAssertEqual(frame.gray(x: x, y: 960), levels[band], accuracy: 10, "t \(t): x \(x) should show band \(band)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 3, "t \(t)")
        }
    }

    func testMovingAimWorksWithLabelAndSlowMo() async throws {
        let clip = try await banded(seconds: 3, fps: 30)
        let slowMo = FileManager.default.temporaryDirectory.appending(path: "aim-slowmo-\(UUID().uuidString).mov")
        files.append(slowMo)
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: SlowMoSegment(start: 1, end: 2), speed: .half, to: slowMo) { _ in }
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: nil, date: .now)
        let output = try await export(slowMo, framing: VerticalFraming(zoom: 0.6), aim: AimPath(keys: [key(0, 0.2), key(3.5, 0.8)]), label: label)
        let lengths = (try await AVURLAsset(url: output).load(.duration).seconds, try await AVURLAsset(url: slowMo).load(.duration).seconds)
        XCTAssertEqual(lengths.0, lengths.1, accuracy: 0.15)
        let size = try await SlowMoComposer.displaySize(of: output)
        XCTAssertEqual(size, ExportFormat.verticalRenderSize)
        let start = try await DecodedFrame(of: output, at: 0.1).meanGray(row: 400)
        let end = try await DecodedFrame(of: output, at: 3.8).meanGray(row: 400)
        XCTAssertLessThan(start, end, "moved right over the slow-mo file")
    }

    /// Static against 3-point export of the same synthetic clip, printed as `AIM|` lines (the
    /// decision's numbers come from real footage, `AimKeyframesTimingTests`).
    func testThreePointExportCostsAboutTheSameAsStatic() async throws {
        let source = try await banded(seconds: 6, fps: 30)
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: nil, date: .now)
        var times: [String: Double] = [:]
        for (name, aim) in [("static", nil as AimPath?), ("3 points", AimPath(keys: [key(0.5, 0), key(3, 1), key(5, 0.5)]))] {
            let begin = Date()
            _ = try await export(source, framing: VerticalFraming(zoom: 0.6), aim: aim, label: label)
            times[name] = Date().timeIntervalSince(begin)
            print("AIM|synthetic 1920×1080 6 s|\(name)|\(String(format: "%.2f", times[name]!))")
        }
        XCTAssertLessThan(times["3 points"]!, times["static"]! * 2 + 1, "no big extra cost")
    }

    // MARK: Helpers

    private func banded(seconds: Int, fps: Int = 10) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "aim-src-\(UUID().uuidString).mov")
        files.append(url)
        try await BandedVideo.make(at: url, size: Self.hd, seconds: seconds, fps: fps)
        return url
    }

    private func export(_ source: URL, framing: VerticalFraming, aim: AimPath?, label: LabelStep.LabelText? = nil) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "aim-out-\(UUID().uuidString).mov")
        files.append(output)
        let plan = ExportPlan(source: source, format: .vertical, label: label, quality: .hd1080, framing: framing, aim: aim)
        try await ClipExtractor.exportForSharing(plan, to: output) { _ in }
        return output
    }
}

private final class Photos: PhotoLibrarySaving, @unchecked Sendable {
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws {}
}
