import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Repeatable Undo, by identifier, identical for playback marking (imported games) and live
/// recording — plus deleting clips removes exactly their files.
@MainActor
final class MarkUndoTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var createdFiles: [URL] = []
    private var now: CFTimeInterval = 1000

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, Mark.self, Clip.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.prepareDirectories()
        now = 1000
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: The stack

    func testStackPopsNewestFirstAndForgetsAfterTheWindow() async throws {
        let stack = MarkUndoStack(window: .milliseconds(300))
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach(stack.push)
        XCTAssertEqual(stack.popLatest(), ids[4])
        XCTAssertEqual(stack.popLatest(), ids[3])
        XCTAssertEqual(stack.ids, Array(ids[0..<3]))
        XCTAssertTrue(stack.canUndo)

        await waitUntil({ !stack.canUndo }, timeout: 2)
        XCTAssertFalse(stack.canUndo, "an idle Undo hides and forgets old taps")
        XCTAssertNil(stack.popLatest())
    }

    func testEachActionKeepsTheBurstAlive() async throws {
        let stack = MarkUndoStack(window: .milliseconds(400))
        stack.push(UUID())
        try await Task.sleep(for: .milliseconds(250))
        stack.push(UUID())
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(stack.ids.count, 2, "the second tap restarted the window")
        _ = stack.popLatest()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(stack.canUndo, "an undo restarts it too")
    }

    // MARK: Acceptance: tap 5, undo 3 → 2 marks with the right times

    /// Recording: the fake camera reports each tap's recording time.
    func testRecordedGameTapFiveUndoThree() async throws {
        let service = FakeRecordingService()
        let session = RecordingSession(service: service, context: context, freeSpace: { 50_000_000_000 },
                                       clock: { [unowned self] in now })
        await session.prepare(preflight: [])
        await session.start()

        for time in [12.0, 25.0, 40.0, 61.0, 75.0] {
            service.markTime = time
            XCTAssertTrue(session.placeMark())
            now += 2.5
        }
        XCTAssertEqual(session.undo.ids.count, 5)
        session.undoLastMark()
        session.undoLastMark()
        session.undoLastMark()

        let game = try XCTUnwrap(session.game)
        XCTAssertEqual(game.marks.map(\.offsetSeconds).sorted(), [12, 25])
        XCTAssertEqual(session.markCount, 2)
        XCTAssertTrue(session.canUndo, "two taps are still undoable")
        session.shutdown()
    }

    /// Playback marking on an imported game. Taps are deliberately out of time order, so undoing
    /// by position (or by latest time) would remove the wrong marks.
    func testImportedGameTapFiveUndoThree() async throws {
        let filename = StorageManager.makeGameVideoFilename(id: UUID(), fileExtension: "mov")
        let url = StorageManager.gameVideoURL(filename: filename)
        try await TestMedia.makeVideo(at: url, seconds: 40, fps: 5, withTone: false)
        createdFiles.append(url)
        let game = Game(label: "", recordedAt: .now, videoFilename: filename, durationSeconds: 40,
                        source: .imported, videoFileSize: StorageManager.fileSize(at: url))
        context.insert(game)
        let session = MarkingSession(game: game, context: context, clock: { [unowned self] in now })
        defer { session.tearDown() }

        let taps: [Double] = [5, 10, 30, 20, 15]
        for time in taps {
            session.seek(to: time)
            await waitUntil { abs(session.player.currentTime().seconds - time) < 0.05 }
            XCTAssertTrue(session.placeMark(), "tap at \(time)")
            now += 2.5
        }
        XCTAssertEqual(game.marks.map(\.offsetSeconds).sorted(), [5, 10, 15, 20, 30])

        session.undoLastMark()
        session.undoLastMark()
        session.undoLastMark()

        // The last three taps were 30, 20, 15 — not the three latest times or the last three rows.
        XCTAssertEqual(game.marks.map(\.offsetSeconds).sorted(), [5, 10])
        XCTAssertEqual(session.markCount, 2)
    }

    func testUndoSkipsAMarkThatIsAlreadyGone() async throws {
        let service = FakeRecordingService()
        let session = RecordingSession(service: service, context: context, freeSpace: { 50_000_000_000 },
                                       clock: { [unowned self] in now })
        await session.prepare(preflight: [])
        await session.start()
        service.markTime = 10
        session.placeMark()
        now += 3
        service.markTime = 20
        session.placeMark()
        let game = try XCTUnwrap(session.game)
        // The newest mark disappears some other way; Undo moves on to the next one.
        let newest = try XCTUnwrap(game.marks.first { $0.offsetSeconds == 20 })
        context.delete(newest)
        try context.save()

        session.undoLastMark()
        XCTAssertTrue(game.marks.isEmpty)
        session.shutdown()
    }

    // MARK: Deleting clips

    func testDeletingClipsRemovesTheirFilesOnly() throws {
        let game = Game(label: "", recordedAt: .now, videoFilename: "g.mov", durationSeconds: 60,
                        source: .recorded, videoFileSize: 1)
        context.insert(game)
        var clips: [Clip] = []
        var files: [UUID: [URL]] = [:]
        for index in 0..<3 {
            let id = UUID()
            let filename = StorageManager.makeClipFilename(id: id)
            let slowMo = StorageManager.makeSlowMoFilename(clipID: id, speed: .half)
            let urls = [StorageManager.clipURL(filename: filename), StorageManager.clipURL(filename: slowMo),
                        StorageManager.thumbnailURL(forClipID: id)]
            for url in urls { try Data("x".utf8).write(to: url) }
            createdFiles += urls
            files[id] = urls
            let clip = Clip(id: id, filename: filename, startSeconds: Double(index * 20), endSeconds: Double(index * 20 + 13), fileSize: 1)
            clip.slowMoFilename = slowMo
            context.insert(clip)
            clip.game = game
            clips.append(clip)
        }
        try context.save()

        StorageManager.deleteClips([clips[0], clips[2]], in: context)

        for clip in [clips[0], clips[2]] {
            for url in files[clip.id]! { XCTAssertFalse(StorageManager.fileExists(at: url), url.lastPathComponent) }
        }
        for url in files[clips[1].id]! { XCTAssertTrue(StorageManager.fileExists(at: url), url.lastPathComponent) }
        XCTAssertEqual(game.clips.map(\.id), [clips[1].id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 1)
    }
}
