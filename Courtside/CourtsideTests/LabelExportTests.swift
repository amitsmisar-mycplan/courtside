import AVFoundation
import CoreGraphics
import SwiftData
import XCTest
@testable import Courtside

/// The burned-in game label in real exports (decision 0019): frames are sampled from the exported
/// file and compared with the same moment of the plain video, inside the label's box.
final class LabelExportTests: XCTestCase {
    private var files: [URL] = []

    override func setUp() {
        StorageManager.prepareDirectories()
    }

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mov")
        files.append(url)
        return url
    }

    private let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)

    /// Mid-gray 1280×720 at 30 fps, so the dark label box stands out wherever it's drawn.
    private func makeSource(seconds: Int) async throws -> URL {
        let url = tempURL("source")
        try await TestMedia.makeVideo(at: url, seconds: seconds, fps: 30, size: CGSize(width: 1280, height: 720), gray: 128, withTone: true)
        return url
    }

    private func export(_ source: URL, format: ExportFormat, labelled: Bool) async throws -> URL {
        let output = tempURL("export")
        let plan = ExportPlan(source: source, format: format, frameSteps: labelled ? [LabelStep(label: label)] : [])
        try await ClipExtractor.exportForSharing(plan, to: output) { _ in }
        return output
    }

    /// Mean brightness 0...1 of `rect` (top-left origin) in the frame at `seconds`, as Photos shows it.
    private func brightness(of url: URL, at seconds: Double, in rect: CGRect) async throws -> Double {
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

    /// A patch inside the label box's lower-left padding (box only, no text), top-left origin.
    private func labelPatch(canvas: CGSize) -> CGRect {
        let placement = LabelPlacement(canvas: canvas)
        let bottom = placement.origin.y + 2, top = placement.origin.y + placement.padding.height - 2
        return CGRect(x: placement.origin.x + 2, y: canvas.height - top,
                      width: placement.padding.width - 4, height: top - bottom)
    }

    /// How much darker the label patch is in `output` than in `plain` at `seconds`. On mid-gray the
    /// box darkens it by about 0.12–0.15 (Core Image blends in linear light); without a label the
    /// difference stays under 0.04, so 0.08 cleanly separates the two.
    private func darkening(_ output: URL, _ plain: URL, at seconds: Double, canvas: CGSize) async throws -> Double {
        let patch = labelPatch(canvas: canvas)
        let labelled = try await brightness(of: output, at: seconds, in: patch)
        let reference = try await brightness(of: plain, at: seconds, in: patch)
        return reference - labelled
    }

    func testThirteenSecondClipShowsLabelAtOpenAndCloseOnly() async throws {
        let source = try await makeSource(seconds: 13)
        let output = try await export(source, format: .original, labelled: true)
        let canvas = CGSize(width: 1280, height: 720)

        let open = try await darkening(output, source, at: 1, canvas: canvas)
        let middle = try await darkening(output, source, at: 6, canvas: canvas)
        let close = try await darkening(output, source, at: 12, canvas: canvas)
        XCTAssertGreaterThan(open, 0.08, "label at 1 s")
        XCTAssertGreaterThan(close, 0.08, "label at 12 s")
        XCTAssertLessThan(abs(middle), 0.04, "plain video at 6 s")

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 13, accuracy: 0.1, "the label doesn't change the length")
    }

    func testThreeSecondClipShowsLabelOnlyAtOpen() async throws {
        let source = try await makeSource(seconds: 3)
        let output = try await export(source, format: .original, labelled: true)
        let canvas = CGSize(width: 1280, height: 720)

        let open = try await darkening(output, source, at: 0.5, canvas: canvas)
        let afterThird = try await darkening(output, source, at: 1.5, canvas: canvas)
        let end = try await darkening(output, source, at: 2.6, canvas: canvas)
        XCTAssertGreaterThan(open, 0.08, "label at the open")
        XCTAssertLessThan(abs(afterThird), 0.04, "gone after a third of the clip")
        XCTAssertLessThan(abs(end), 0.04, "no closing label under 7 s")
    }

    func testVerticalExportCarriesTheLabelAboveTheSocialBand() async throws {
        let source = try await makeSource(seconds: 8)
        let labelled = try await export(source, format: .vertical, labelled: true)
        let plain = try await export(source, format: .vertical, labelled: false)
        let canvas = ExportFormat.verticalRenderSize

        let open = try await darkening(labelled, plain, at: 1, canvas: canvas)
        let middle = try await darkening(labelled, plain, at: 4, canvas: canvas)
        let close = try await darkening(labelled, plain, at: 7, canvas: canvas)
        XCTAssertGreaterThan(open, 0.08)
        XCTAssertGreaterThan(close, 0.08, "8 s clip: closing label too")
        XCTAssertLessThan(abs(middle), 0.04)
        // The bottom fifth, where Instagram and TikTok draw their captions, is untouched.
        let band = CGRect(x: 40, y: 1920 * 0.82, width: 700, height: 200)
        let bandLabelled = try await brightness(of: labelled, at: 1, in: band)
        let bandPlain = try await brightness(of: plain, at: 1, in: band)
        XCTAssertEqual(bandLabelled, bandPlain, accuracy: 0.03)
    }

    func testLongerRenderGetsItsClosingLabelAtItsOwnEnd() async throws {
        // A slow-mo render or trimmed clip is just a source of a different length: the windows
        // come from the exported file's duration.
        let source = try await makeSource(seconds: 9)
        let output = try await export(source, format: .original, labelled: true)
        let canvas = CGSize(width: 1280, height: 720)
        let atOldEnd = try await darkening(output, source, at: 5, canvas: canvas)
        let atNewEnd = try await darkening(output, source, at: 8, canvas: canvas)
        XCTAssertLessThan(abs(atOldEnd), 0.04)
        XCTAssertGreaterThan(atNewEnd, 0.08)
    }
}

/// Stands in for Photos and records what would have been saved.
private final class RecordingPhotos: PhotoLibrarySaving, @unchecked Sendable {
    var saved: [URL] = []
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws { saved.append(url) }
}

/// Original keeps its fast path (the clip saved as it is) unless a label has to be drawn.
@MainActor
final class LabelExportSessionTests: XCTestCase {
    private var source: URL!

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        source = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        try await TestMedia.makeVideo(at: source, seconds: 3, fps: 30, withTone: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: source)
    }

    private func makeGame() -> Game {
        Game(label: "", recordedAt: .now, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
    }

    func testOriginalWithLabelIsRendered() async throws {
        let game = makeGame()
        game.opponent = "Lakers"
        let photos = RecordingPhotos()
        let session = ClipExportSession(clipID: UUID(), source: source, label: .forExport(game: game, mode: .openAndClose), photos: photos)
        XCTAssertTrue(session.addsLabel)
        XCTAssertFalse(session.plan(for: .original).isUnchangedSource)
        session.export(.original)
        await session.finish()
        XCTAssertEqual(session.phase, .saved(.original))
        XCTAssertEqual(photos.saved.count, 1)
        XCTAssertNotEqual(photos.saved.first, source, "rendered to a temporary file, not the clip itself")
    }

    func testSettingOffKeepsTheFastPath() async throws {
        let game = makeGame()
        game.opponent = "Lakers"
        let photos = RecordingPhotos()
        let session = ClipExportSession(clipID: UUID(), source: source, label: .forExport(game: game, mode: .off), photos: photos)
        XCTAssertFalse(session.addsLabel)
        session.export(.original)
        await session.finish()
        XCTAssertEqual(photos.saved, [source], "saved as it is, no render")
    }

    func testEmptyLabelKeepsTheFastPath() async throws {
        let photos = RecordingPhotos()
        let session = ClipExportSession(clipID: UUID(), source: source, label: .forExport(game: makeGame(), mode: .openAndClose), photos: photos)
        XCTAssertNil(session.label, "nothing to draw")
        session.export(.original)
        await session.finish()
        XCTAssertEqual(photos.saved, [source])
    }
}
