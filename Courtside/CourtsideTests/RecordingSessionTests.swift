import QuartzCore
import SwiftData
import XCTest
@testable import Courtside

/// Stands in for the camera so the recording flow can be tested in the Simulator.
final class FakeRecordingService: RecordingService {
    var prepareError: Error?
    var markTime: Double = 0
    var stopDuration: Double = 0
    var stopError: Error?
    var refocusCount = 0
    var didShutdown = false
    /// The file the current (or last) recording writes; each start makes a new one, like the camera.
    private(set) var url = StorageManager.gameVideoURL(filename: "fake-\(UUID().uuidString).mov")
    private(set) var startCount = 0
    var onUnexpectedFinish: (@MainActor (URL, Double) -> Void)?

    /// The phone's back lenses; both by default.
    var lensesOnPhone: [CameraLens] = CameraLens.allCases
    var selectLensError: Error?
    private(set) var preferredLensAsked: CameraLens??
    private(set) var selectedLenses: [CameraLens] = []
    private(set) var lens: CameraLens?
    var availableLenses: [CameraLens] { lensesOnPhone }

    func prepare(preferredLens: CameraLens?) async throws {
        preferredLensAsked = .some(preferredLens)
        if let prepareError { throw prepareError }
        lens = LensSettings.choose(saved: preferredLens, available: lensesOnPhone)
    }
    func selectLens(_ lens: CameraLens) async throws {
        selectedLenses.append(lens)
        if let selectLensError { throw selectLensError }
        self.lens = lens
    }
    func startRecording() async throws -> URL {
        if startCount > 0 { url = StorageManager.gameVideoURL(filename: "fake-\(UUID().uuidString).mov") }
        startCount += 1
        return url
    }
    func stopRecording() async throws -> (url: URL, duration: Double) {
        if let stopError { throw stopError }
        return (url, stopDuration)
    }
    func mark() -> Double { markTime }
    func refocus() { refocusCount += 1 }
    func shutdown() { didShutdown = true }
}

@MainActor
final class RecordingSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var service: FakeRecordingService!
    private var now: CFTimeInterval = 1000
    private var free: Int64 = 50_000_000_000

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        service = FakeRecordingService()
        now = 1000
        free = 50_000_000_000
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(service: service, context: container.mainContext, freeSpace: { [unowned self] in free }, clock: { [unowned self] in now })
    }

    private func recordingSession() async -> RecordingSession {
        let session = makeSession()
        await session.prepare(preflight: [])
        await session.start()
        return session
    }

    func testPrepareFailureShowsMessageAndSettingsHint() async {
        service.prepareError = RecordingError.cameraDenied
        let session = makeSession()
        await session.prepare(preflight: [])
        XCTAssertEqual(session.phase, .failed(RecordingError.cameraDenied.localizedDescription))
        XCTAssertTrue(session.failureNeedsSettings)
    }

    func testBlockingPreflightPreventsStart() async {
        let session = makeSession()
        await session.prepare(preflight: [RecordingPreflight.Issue(id: "disk", message: "", blocksRecording: true)])
        XCTAssertFalse(session.canStart)
        await session.start()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.game)
    }

    func testStartCreatesRecordedGameImmediately() async {
        let session = await recordingSession()
        XCTAssertEqual(session.phase, .recording)
        let game = try! XCTUnwrap(session.game)
        XCTAssertEqual(game.source, .recorded)
        XCTAssertEqual(game.firstPart.videoFilename, service.url.lastPathComponent)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Game>()), 1, "saved before any footage is at risk")
        // No details are asked for before recording; they're added afterwards.
        XCTAssertEqual(game.displayTitle, "Untitled game")
        XCTAssertNil(game.opponent)
    }

    func testMarksUseRecordingTimeWithDebounceAndUndo() async {
        let session = await recordingSession()
        service.markTime = 12.5
        XCTAssertTrue(session.placeMark())
        now += 1
        service.markTime = 13.5
        XCTAssertFalse(session.placeMark(), "debounced within 2 s")
        now += 2
        service.markTime = 15.5
        XCTAssertTrue(session.placeMark())
        XCTAssertEqual(session.game?.marks.map(\.offsetSeconds).sorted(), [12.5, 15.5])

        session.undoLastMark()
        XCTAssertEqual(session.markCount, 1)
        XCTAssertEqual(session.game?.marks.map(\.offsetSeconds), [12.5])
        session.undoLastMark()
        XCTAssertEqual(session.markCount, 0, "undo is repeatable")
        XCTAssertFalse(session.canUndo)
    }

    func testNoMarksBeforeRecording() async {
        let session = makeSession()
        await session.prepare(preflight: [])
        XCTAssertFalse(session.placeMark())
    }

    func testStopSavesDuration() async {
        let session = await recordingSession()
        service.stopDuration = 95
        await session.stop()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.game?.durationSeconds, 95)
        XCTAssertNil(session.endNote, "parent stopped it, no explanation needed")
    }

    func testStopStillSavesWhenRecordingAlreadyEnded() async {
        let session = await recordingSession()
        service.markTime = 40
        session.tick()
        service.stopError = RecordingError.notRecording
        await session.stop()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.game?.durationSeconds, 40, "falls back to elapsed time")
    }

    func testUnexpectedFinishSavesAndExplains() async throws {
        let session = await recordingSession()
        service.onUnexpectedFinish?(service.url, 61)
        for _ in 0..<50 where session.phase != .finished { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.game?.durationSeconds, 61)
        XCTAssertNotNil(session.endNote)
    }

    func testBackgroundingStopsAndSaves() async {
        let session = await recordingSession()
        service.stopDuration = 30
        await session.handleBackground()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertNotNil(session.endNote)
    }

    func testLowDiskStopsAndSaves() async {
        let session = await recordingSession()
        await session.checkDiskSpace()
        XCTAssertEqual(session.phase, .recording, "plenty of space")
        free = 500_000_000
        service.stopDuration = 3000
        await session.checkDiskSpace()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.game?.durationSeconds, 3000)
        XCTAssertNotNil(session.endNote)
    }

    func testScreenDimsAfterThirtySecondsIdleAndWakesOnTap() async {
        let session = await recordingSession()
        now += 29
        session.tick()
        XCTAssertFalse(session.isDimmed)
        now += 2
        session.tick()
        XCTAssertTrue(session.isDimmed)
        XCTAssertTrue(session.placeMark(), "a tap still marks while dimmed")
        XCTAssertFalse(session.isDimmed)
    }

    func testRefocusAndShutdownReachTheCamera() async {
        let session = await recordingSession()
        session.refocus()
        XCTAssertEqual(service.refocusCount, 1)
        session.shutdown()
        XCTAssertTrue(service.didShutdown)
    }

    // MARK: Recording again (fix/recording-flow)

    /// The cause found at the game: once stopped, the session is `.finished` for good. `start()`
    /// needs `.ready`, so it does nothing, and the screen offers only Make Clips and Done.
    func testStartAfterStopDoesNothingOnItsOwn() async throws {
        let session = await recordingSession()
        await session.stop()
        XCTAssertFalse(session.canStart)
        await session.start()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(service.startCount, 1)
    }

    func testStoppingThenRecordingAgainAddsPart2ToTheSameGame() async throws {
        let session = await recordingSession()
        service.markTime = 4
        session.placeMark()
        service.stopDuration = 1.2
        await session.stop()
        XCTAssertEqual(session.phase, .finished)
        let game = try XCTUnwrap(session.game)

        // The finished screen offers to record again; the camera is still running.
        session.recordAgain()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.canStart)
        now += 10
        await session.start()
        XCTAssertEqual(session.phase, .recording)
        XCTAssertTrue(session.game === game, "the same game")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Game>()).count, 1, "no new game")
        XCTAssertEqual(game.orderedParts.count, 2)
        let part2 = game.orderedParts[1]
        XCTAssertEqual(part2.videoFilename, service.url.lastPathComponent)
        XCTAssertNotEqual(part2.videoFilename, game.orderedParts[0].videoFilename)
        XCTAssertEqual(session.markCount, 0, "counts restart for the new part")

        service.markTime = 2
        session.placeMark()
        service.stopDuration = 30
        await session.stop()
        XCTAssertEqual(game.orderedParts[0].durationSeconds, 1.2, accuracy: 0.001, "Part 1 kept, even at 1.2 s")
        XCTAssertEqual(part2.durationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(game.legacyDurationSeconds, 1.2, accuracy: 0.001, "the legacy fields stay Part 1's")
        let marks = game.marks.sorted { $0.offsetSeconds < $1.offsetSeconds }
        XCTAssertEqual(marks.map(\.offsetSeconds), [2, 4])
        XCTAssertTrue(marks[0].part === part2, "a mark in Part 2 belongs to Part 2")
        XCTAssertTrue(marks[1].part === game.orderedParts[0])
    }

    func testRecordingFromAnImportedOrMixedGameAddsItsNextPart() async throws {
        let context = container.mainContext
        let imported = Game(label: "", recordedAt: .now, videoFilename: "imported.mov", durationSeconds: 600,
                            source: .imported, videoFileSize: 1)
        context.insert(imported)
        try context.save()
        for expectedParts in [2, 3] {
            // An imported game, then the same game now mixing an import and a recording.
            let session = RecordingSession(service: service, context: context, freeSpace: { [unowned self] in free },
                                           clock: { [unowned self] in now }, game: imported)
            await session.prepare(preflight: [])
            await session.start()
            service.stopDuration = 5
            await session.stop()
            XCTAssertTrue(session.game === imported)
            XCTAssertEqual(imported.orderedParts.count, expectedParts)
            XCTAssertEqual(imported.orderedParts.last?.durationSeconds ?? 0, 5, accuracy: 0.001)
        }
        XCTAssertEqual(imported.source, .imported, "where the game came from doesn't change")
        XCTAssertEqual(imported.legacyDurationSeconds, 600, "Part 1's fields untouched")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Game>()).count, 1)
    }

    func testRecordAgainOnlyAfterAFinishedRecording() async {
        let session = makeSession()
        await session.prepare(preflight: [])
        session.recordAgain()
        XCTAssertEqual(session.phase, .ready, "unchanged before any recording")
        await session.start()
        session.recordAgain()
        XCTAssertEqual(session.phase, .recording, "can't jump back while recording")
    }

    // MARK: Wake guard (fix/recording-flow)

    func testTapsRightAfterWakingDoNotMark() async {
        let session = await recordingSession()
        // The app came back to the front (or the screen appeared): the first second only wakes.
        session.ignoreTapsBriefly()
        now += 0.5
        XCTAssertFalse(session.placeMark(), "the wake-up touch")
        XCTAssertEqual(session.markCount, 0)
        XCTAssertFalse(session.isDimmed, "but it still wakes the screen")
        now += 0.49
        XCTAssertFalse(session.placeMark())
        now += 0.02
        XCTAssertTrue(session.placeMark(), "after a second, taps mark as usual")
        XCTAssertEqual(session.markCount, 1)
    }

    func testMarkingDuringPlayIsUnchanged() async {
        let session = await recordingSession()
        // No wake event: the first tap marks, and the 2 s debounce is the only limit, as before.
        XCTAssertTrue(session.placeMark())
        now += 2
        XCTAssertTrue(session.placeMark())
        XCTAssertEqual(session.markCount, 2)
    }

    func testRecordingAgainResetsTheCountsAndTheDebounce() async {
        let session = await recordingSession()
        session.placeMark()
        await session.stop()
        session.recordAgain()
        await session.start()
        XCTAssertEqual(session.markCount, 0)
        XCTAssertTrue(session.placeMark(), "the debounce from Part 1 doesn't carry over")
    }
}
