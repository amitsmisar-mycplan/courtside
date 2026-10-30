import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Full-screen preview: one player, one item reused while settings are unchanged, released on
/// teardown; and the clip's on-screen shape, which picks the preview's orientation.
@MainActor
final class SlowMoPreviewTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: Game.self, Mark.self, Clip.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        createdFiles.forEach(StorageManager.removeFile(at:))
    }

    /// A 6 s, 60 fps clip file (no game video needed), with the tap at 4 s.
    private func makeClip(transform: CGAffineTransform = .identity) async throws -> Clip {
        let clipID = UUID()
        let filename = StorageManager.makeClipFilename(id: clipID)
        let url = StorageManager.clipURL(filename: filename)
        try await TestMedia.makeVideo(at: url, seconds: 6, fps: 60, transform: transform, withTone: true)
        createdFiles.append(url)
        let clip = Clip(id: clipID, filename: filename, startSeconds: 10, endSeconds: 16,
                        fileSize: StorageManager.fileSize(at: url), markSeconds: 14)
        context.insert(clip)
        return clip
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testLandscapeClipLoadsPosterAndShape() async throws {
        let session = SlowMoSession(clip: try await makeClip())
        defer { session.tearDown() }
        await session.load()
        XCTAssertEqual(try XCTUnwrap(session.aspectRatio), 320.0 / 180.0, accuracy: 0.01)
        XCTAssertFalse(session.isPortrait)
        let poster = try XCTUnwrap(session.poster)
        XCTAssertGreaterThan(poster.size.width, poster.size.height)
    }

    func testRotatedClipIsPortrait() async throws {
        // Stored 320×180 with a 90° rotation, like a phone filmed upright.
        let session = SlowMoSession(clip: try await makeClip(transform: CGAffineTransform(rotationAngle: .pi / 2)))
        defer { session.tearDown() }
        await session.load()
        XCTAssertEqual(try XCTUnwrap(session.aspectRatio), 180.0 / 320.0, accuracy: 0.01)
        XCTAssertTrue(session.isPortrait)
        let poster = try XCTUnwrap(session.poster)
        XCTAssertLessThan(poster.size.width, poster.size.height, "poster is upright")
    }

    func testPreviewReusesItemUntilSettingsChangeAndTearDownReleasesIt() async throws {
        let session = SlowMoSession(clip: try await makeClip())
        await session.load()
        XCTAssertEqual(session.availableSpeeds, [.half, .quarter])

        session.preview()
        await waitUntil { session.hasPreview }
        let first = try XCTUnwrap(session.player.currentItem)

        // Close and reopen with the same settings: same item, not a second composition.
        session.closePreview()
        XCTAssertEqual(session.player.rate, 0)
        session.preview()
        XCTAssertTrue(session.player.currentItem === first)

        // A settings change drops the old item; the next preview builds a new one.
        session.closePreview()
        session.select(.quarter)
        XCTAssertNil(session.player.currentItem)
        XCTAssertEqual(session.speed, .quarter)
        session.preview()
        await waitUntil { session.hasPreview }
        XCTAssertFalse(session.player.currentItem === first)

        session.tearDown()
        XCTAssertNil(session.player.currentItem)
        XCTAssertFalse(session.hasPreview)
    }

    func testPauseAndResume() async throws {
        let session = SlowMoSession(clip: try await makeClip())
        defer { session.tearDown() }
        await session.load()
        session.preview()
        await waitUntil { session.hasPreview && session.player.rate > 0 }

        session.togglePreviewPause()
        XCTAssertTrue(session.isPreviewPaused)
        XCTAssertEqual(session.player.rate, 0)
        session.togglePreviewPause()
        XCTAssertFalse(session.isPreviewPaused)
        XCTAssertGreaterThan(session.player.rate, 0)
    }

    func testClosingDuringBuildNeverStartsPlayback() async throws {
        let session = SlowMoSession(clip: try await makeClip())
        defer { session.tearDown() }
        await session.load()
        session.preview()
        session.closePreview()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(session.hasPreview)
        XCTAssertEqual(session.player.rate, 0)
    }
}
