import QuartzCore
import SwiftData
import XCTest
@testable import Courtside

/// Stands in for the camera so the recording flow can be tested in the Simulator.
private final class FakeRecordingService: RecordingService {
    var prepareError: Error?
    var markTime: Double = 0
    var stopDuration: Double = 0
    var stopError: Error?
    var refocusCount = 0
    var didShutdown = false
    let url = StorageManager.gameVideoURL(filename: "fake-\(UUID().uuidString).mov")
    var onUnexpectedFinish: (@MainActor (URL, Double) -> Void)?

    func prepare() async throws { if let prepareError { throw prepareError } }
    func startRecording() async throws -> URL { url }
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
        container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        XCTAssertEqual(game.videoFilename, service.url.lastPathComponent)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Game>()), 1, "saved before any footage is at risk")
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
}
