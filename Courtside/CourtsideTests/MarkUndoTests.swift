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

    /// Each clip's own mark goes with it; marks for other clips, pending marks, and the mark of a
    /// clip made before tap times were stored are left alone.
    func testDeletingClipsDeletesTheirMarksSoCountsMatch() throws {
        let game = Game(label: "", recordedAt: .now, videoFilename: "g.mov", durationSeconds: 120,
                        source: .imported, videoFileSize: 1)
        context.insert(game)
        func addMark(_ offset: Double, extracted: Bool) {
            let mark = Mark(offsetSeconds: offset)
            mark.isExtracted = extracted
            context.insert(mark)
            mark.game = game
        }
        func addClip(tap: Double?, start: Double) -> Clip {
            let id = UUID()
            let clip = Clip(id: id, filename: StorageManager.makeClipFilename(id: id), startSeconds: start,
                            endSeconds: start + 13, fileSize: 1, markSeconds: tap)
            context.insert(clip)
            clip.game = game
            return clip
        }
        for offset in [20.0, 50.0, 80.0] { addMark(offset, extracted: true) }
        addMark(100, extracted: false)  // tapped, not made into a clip yet
        addMark(110, extracted: true)   // behind an older clip with no stored tap
        let first = addClip(tap: 20, start: 10)
        let second = addClip(tap: 50, start: 40)
        _ = addClip(tap: 80, start: 70)
        let legacy = addClip(tap: nil, start: 97)
        try context.save()
        XCTAssertEqual(game.marks.count, 5)

        StorageManager.deleteClips([first, second], in: context)

        XCTAssertEqual(game.clips.count, 2)
        XCTAssertEqual(game.marks.map(\.offsetSeconds).sorted(), [80, 100, 110])
        XCTAssertEqual(game.marks.filter(\.isExtracted).count, game.clips.count, "made marks match clips")

        StorageManager.deleteClips([legacy], in: context)
        XCTAssertEqual(game.marks.map(\.offsetSeconds).sorted(), [80, 100, 110], "no guessing for older clips")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Mark>()), 3)
    }
}
