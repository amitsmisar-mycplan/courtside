import SwiftData
import XCTest
@testable import Courtside

/// Stands in for Photos: grants or refuses access and records what would have been saved.
private final class FakePhotos: PhotoLibrarySaving, @unchecked Sendable {
    var access: PhotoAccess = .granted
    var accessRequests = 0
    var saved: [URL] = []
    /// Whether each file existed at the moment it was handed to Photos.
    var existedWhenSaved: [Bool] = []

    func requestAddAccess() async -> PhotoAccess {
        accessRequests += 1
        return access
    }

    func saveVideo(at url: URL) async throws {
        saved.append(url)
        existedWhenSaved.append(FileManager.default.fileExists(atPath: url.path))
    }
}

/// The export flow: permission first, render, save, then the temporary file is gone.
@MainActor
final class ClipExportSessionTests: XCTestCase {
    private var source: URL!

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        source = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        try await TestMedia.makeVideo(at: source, seconds: 3, fps: 30, withTone: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: source)
    }

    private func exportsFor(_ clipID: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: StorageManager.exportsDirectory.path)) ?? [])
            .filter { $0.hasPrefix(clipID.uuidString) }
    }

    func testVerticalSavesThenRemovesTheTemporaryFile() async throws {
        let photos = FakePhotos()
        let session = ClipExportSession(clipID: UUID(), source: source, photos: photos)
        session.export(.vertical)
        await session.finish()

        XCTAssertEqual(session.phase, .saved(.vertical))
        XCTAssertEqual(photos.saved.count, 1)
        XCTAssertEqual(photos.existedWhenSaved, [true])
        XCTAssertEqual(photos.saved.first?.deletingLastPathComponent().standardizedFileURL,
                       StorageManager.exportsDirectory.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photos.saved[0].path), "temporary export removed after saving")
        XCTAssertTrue(exportsFor(session.clipID).isEmpty)
    }

    func testOriginalSavesTheClipItselfWithoutRendering() async throws {
        let photos = FakePhotos()
        let session = ClipExportSession(clipID: UUID(), source: source, photos: photos)
        session.export(.original)
        await session.finish()

        XCTAssertEqual(session.phase, .saved(.original))
        XCTAssertEqual(photos.saved, [source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the clip itself is never removed")
        XCTAssertTrue(exportsFor(session.clipID).isEmpty)
    }

    func testDeniedShowsGuidanceAndRendersNothing() async throws {
        let photos = FakePhotos()
        photos.access = .denied
        let session = ClipExportSession(clipID: UUID(), source: source, photos: photos)
        session.export(.vertical)
        await session.finish()

        XCTAssertEqual(session.phase, .denied)
        XCTAssertTrue(photos.saved.isEmpty)
        XCTAssertTrue(exportsFor(session.clipID).isEmpty, "no render when Photos access is off")
    }

    func testCancelSavesNothingAndLeavesNoFiles() async throws {
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID().uuidString).mov")
        try await TestMedia.makeVideo(at: long, seconds: 20, fps: 30, withTone: true)
        defer { try? FileManager.default.removeItem(at: long) }
        let photos = FakePhotos()
        let session = ClipExportSession(clipID: UUID(), source: long, photos: photos)

        session.export(.vertical)
        while session.phase != .exporting { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        session.cancel()
        await session.finish()

        XCTAssertEqual(session.phase, .choosing, "back to the format choice")
        XCTAssertTrue(photos.saved.isEmpty)
        XCTAssertTrue(exportsFor(session.clipID).isEmpty, "no export or partial file left")
    }

    func testLeftoverExportsAreSweptOnLaunch() throws {
        let leftover = StorageManager.makeExportURL(clipID: UUID(), format: .vertical)
        try Data("x".utf8).write(to: leftover)
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.performLaunchCleanup(in: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }
}
