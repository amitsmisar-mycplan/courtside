import AVFoundation
import XCTest
@testable import Courtside

/// Stands in for the share sheet: records what it was handed, measures the label patch while the
/// file still exists, and "closes" at once.
@MainActor
private final class FakeSharer: FileSharing {
    var shared: [URL] = []
    var existedWhenShared: [Bool] = []
    /// Label-box darkening of the shared file at 1 s, against `plain` (measured during the share).
    var darkening: Double?
    var plain: URL?

    func share(_ url: URL) async {
        shared.append(url)
        existedWhenShared.append(FileManager.default.fileExists(atPath: url.path))
        if let plain {
            let patch = Self.labelPatch(canvas: CGSize(width: 1280, height: 720))
            let labelled = (try? await Self.brightness(of: url, at: 1, in: patch)) ?? 0
            let reference = (try? await Self.brightness(of: plain, at: 1, in: patch)) ?? 0
            darkening = reference - labelled
        }
    }

    /// Inside the label box's lower-left padding, top-left origin.
    static func labelPatch(canvas: CGSize) -> CGRect {
        let placement = LabelPlacement(canvas: canvas)
        let bottom = placement.origin.y + 2, top = placement.origin.y + placement.padding.height - 2
        return CGRect(x: placement.origin.x + 2, y: canvas.height - top, width: placement.padding.width - 4, height: top - bottom)
    }

    static func brightness(of url: URL, at seconds: Double, in rect: CGRect) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0, count = 0.0
        for row in Int(rect.minY)..<Int(rect.maxY) {
            for column in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (row * width + column) * 4
                sum += (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / (3 * 255)
                count += 1
            }
        }
        return sum / count
    }
}

/// Share carries the game label like Save to Photos, keeps its instant path without one, and
/// leaves no files behind (decision 0020).
@MainActor
final class ClipShareSessionTests: XCTestCase {
    private var source: URL!
    private let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        source = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        // Mid-gray 1280×720, so the label box is easy to find.
        try await TestMedia.makeVideo(at: source, seconds: 4, fps: 30, size: CGSize(width: 1280, height: 720), gray: 128, withTone: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: source)
    }

    private func exportsFor(_ clipID: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: StorageManager.exportsDirectory.path)) ?? [])
            .filter { $0.hasPrefix(clipID.uuidString) }
    }

    private func makeGame() -> Game {
        Game(label: "", recordedAt: .now, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
    }

    func testShareWithLabelSharesALabelledCopyThenRemovesIt() async throws {
        let sharer = FakeSharer()
        sharer.plain = source
        let session = ClipShareSession(clipID: UUID(), source: source, label: label, sharer: sharer)
        XCTAssertTrue(session.addsLabel)
        XCTAssertEqual(session.plan.format, .original, "no format choice")
        session.start()
        await session.finish()

        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(sharer.shared.count, 1)
        let shared = try XCTUnwrap(sharer.shared.first)
        XCTAssertNotEqual(shared, source, "a rendered copy, not the clip itself")
        XCTAssertEqual(shared.deletingLastPathComponent().standardizedFileURL, StorageManager.exportsDirectory.standardizedFileURL)
        XCTAssertEqual(sharer.existedWhenShared, [true])
        XCTAssertGreaterThan(try XCTUnwrap(sharer.darkening), 0.08, "the shared file carries the label")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path), "removed after the share sheet closed")
        XCTAssertTrue(exportsFor(session.clipID).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the clip itself is never removed")
    }

    func testLabelOffSharesTheClipAtOnce() async throws {
        let game = makeGame()
        game.opponent = "Lakers"
        let sharer = FakeSharer()
        let session = ClipShareSession(clipID: UUID(), source: source, label: .forExport(game: game, mode: .off), sharer: sharer)
        XCTAssertFalse(session.addsLabel)
        session.start()
        await session.finish()
        XCTAssertEqual(sharer.shared, [source], "fast path: the clip file itself, no render")
        XCTAssertTrue(exportsFor(session.clipID).isEmpty)
    }

    func testNoLabelTextSharesTheClipAtOnce() async throws {
        let sharer = FakeSharer()
        let session = ClipShareSession(clipID: UUID(), source: source, label: .forExport(game: makeGame(), mode: .openAndClose), sharer: sharer)
        XCTAssertNil(session.label)
        XCTAssertFalse(session.addsLabel)
        session.start()
        await session.finish()
        XCTAssertEqual(sharer.shared, [source])
        XCTAssertTrue(exportsFor(session.clipID).isEmpty)
    }

    func testCancelLeavesNoFilesAndSharesNothing() async throws {
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: long) }
        try await TestMedia.makeVideo(at: long, seconds: 20, fps: 30, size: CGSize(width: 1280, height: 720), gray: 128, withTone: true)
        let sharer = FakeSharer()
        let session = ClipShareSession(clipID: UUID(), source: long, label: label, sharer: sharer)
        session.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while session.phase != .preparing || session.progress == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        session.cancel()
        await session.finish()

        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertTrue(sharer.shared.isEmpty, "nothing shared")
        XCTAssertTrue(exportsFor(session.clipID).isEmpty, "no partial or finished file left")
    }
}
