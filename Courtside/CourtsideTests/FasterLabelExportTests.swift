import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Labelled exports capped at 1080p and the labelled-copy cache (decision 0021).
@MainActor
final class FasterLabelExportTests: XCTestCase {
    private let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)
    private var files: [URL] = []

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        LabelledExportCache.shared.removeAll()
    }

    override func tearDown() async throws {
        LabelledExportCache.shared.removeAll()
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Mid-gray video in the temp folder, so the dark label box is easy to find. At 4 s the label
    /// shows from 0 to 1.33 s, so it is fully in at 1 s.
    private func makeSource(size: CGSize, transform: CGAffineTransform = .identity, seconds: Int = 4) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "source-\(UUID().uuidString).mov")
        files.append(url)
        try await TestMedia.makeVideo(at: url, seconds: seconds, fps: 30, transform: transform, size: size, gray: 128, withTone: true)
        return url
    }

    private func exportsFor(_ clipID: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: StorageManager.exportsDirectory.path)) ?? [])
            .filter { $0.hasPrefix(clipID.uuidString) }
    }

    private func saveLabelled(
        _ source: URL, format: ExportFormat = .original, quality: LabelledExportQuality,
        clipID: UUID = UUID(), label: LabelStep.LabelText? = nil
    ) async throws -> (ClipExportSession, URL) {
        let photos = Photos()
        let session = ClipExportSession(clipID: clipID, source: source, label: label ?? self.label, quality: quality, photos: photos)
        session.export(format)
        await session.finish()
        XCTAssertEqual(session.phase, .saved(format))
        return (session, try XCTUnwrap(photos.saved.last))
    }

    // MARK: The cap

    func testCappedSizeScalesTheLongSideDownToEvenPixels() {
        let cap = ExportPlan.cappedLongSide
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 3840, height: 2160), maxLongSide: cap), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 2160, height: 3840), maxLongSide: cap), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 1920, height: 1080), maxLongSide: cap), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 1280, height: 720), maxLongSide: cap), CGSize(width: 1280, height: 720), "never scaled up")
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 4000, height: 3000), maxLongSide: cap), CGSize(width: 1920, height: 1440))
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 3000, height: 1999), maxLongSide: cap), CGSize(width: 1920, height: 1280), "even")
        XCTAssertEqual(ExportPlan.cappedSize(CGSize(width: 3840, height: 2160), maxLongSide: nil), CGSize(width: 3840, height: 2160))
    }

    func testOnlyLabelledPlansAreCapped() {
        let url = URL(fileURLWithPath: "/clip.mov")
        XCTAssertEqual(ExportPlan(source: url, format: .original, label: label, quality: .hd1080).maxLongSide, 1920)
        XCTAssertEqual(ExportPlan(source: url, format: .vertical, label: label, quality: .hd1080).maxLongSide, 1920)
        XCTAssertNil(ExportPlan(source: url, format: .original, label: label, quality: .full).maxLongSide, "Full quality: today's behavior")
        let unlabelled = ExportPlan(source: url, format: .original, label: nil, quality: .hd1080)
        XCTAssertNil(unlabelled.maxLongSide)
        XCTAssertTrue(unlabelled.isUnchangedSource, "the fast path is untouched")
        XCTAssertNil(ExportPlan(source: url, format: .vertical, label: nil, quality: .hd1080).maxLongSide, "unlabelled Vertical unchanged")
    }

    func testDefaultQualityIs1080p() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: LabelSettings.labelledQualityKey)
        defer { defaults.set(saved, forKey: LabelSettings.labelledQualityKey) }
        defaults.removeObject(forKey: LabelSettings.labelledQualityKey)
        XCTAssertEqual(LabelSettings.labelledQuality, .hd1080)
        defaults.set(LabelledExportQuality.full.rawValue, forKey: LabelSettings.labelledQualityKey)
        XCTAssertEqual(LabelSettings.labelledQuality, .full)
    }

    // MARK: Real exports

    func testLabelled1080pExportOfALargeClipIs1920x1080AndCarriesTheLabel() async throws {
        let source = try await makeSource(size: CGSize(width: 2560, height: 1440))
        let (_, saved) = try await saveLabelled(source, quality: .hd1080)
        let size = try await SlowMoComposer.displaySize(of: saved)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let darkening = try await Self.labelDarkening(saved, canvas: CGSize(width: 1920, height: 1080))
        XCTAssertGreaterThan(darkening, 0.08)
        let tracks = try await AVURLAsset(url: saved).loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty, "audio kept")
    }

    func testFullQualityKeepsTheClipsResolution() async throws {
        let source = try await makeSource(size: CGSize(width: 2560, height: 1440))
        let (_, saved) = try await saveLabelled(source, quality: .full)
        let size = try await SlowMoComposer.displaySize(of: saved)
        XCTAssertEqual(size, CGSize(width: 2560, height: 1440))
        let darkening = try await Self.labelDarkening(saved, canvas: CGSize(width: 2560, height: 1440))
        XCTAssertGreaterThan(darkening, 0.08)
    }

    func testPortraitClipIsCappedUpright() async throws {
        // Stored 2560×1440 with a quarter turn, shown 1440×2560: as phones save upright video.
        let turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1440, ty: 0)
        let source = try await makeSource(size: CGSize(width: 2560, height: 1440), transform: turn)
        let (_, saved) = try await saveLabelled(source, quality: .hd1080)
        let size = try await SlowMoComposer.displaySize(of: saved)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
    }

    func testLabelledVerticalAt1080pIs1080x1920() async throws {
        let source = try await makeSource(size: CGSize(width: 2560, height: 1440))
        let (_, saved) = try await saveLabelled(source, format: .vertical, quality: .hd1080)
        let size = try await SlowMoComposer.displaySize(of: saved)
        XCTAssertEqual(size, ExportFormat.verticalRenderSize)
    }

    func testSmallClipIsNotScaledUp() async throws {
        let source = try await makeSource(size: CGSize(width: 1280, height: 720))
        let (_, saved) = try await saveLabelled(source, quality: .hd1080)
        let size = try await SlowMoComposer.displaySize(of: saved)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
    }

    // MARK: Cache

    func testShareAfterSaveReusesTheLabelledCopy() async throws {
        let source = try await makeSource(size: CGSize(width: 1280, height: 720))
        let clipID = UUID()
        let (_, saved) = try await saveLabelled(source, quality: .hd1080, clipID: clipID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "kept for next time")

        let sharer = Sharer()
        let share = ClipShareSession(clipID: clipID, source: source, label: label, quality: .hd1080, sharer: sharer)
        XCTAssertTrue(share.addsLabel)
        XCTAssertFalse(share.needsRender, "no progress sheet")
        share.start()
        await share.finish()
        XCTAssertEqual(share.phase, .finished)
        XCTAssertEqual(sharer.shared, [saved], "the same file, not a new render")
        XCTAssertEqual(exportsFor(clipID).count, 1)

        // And saving again.
        let (again, savedAgain) = try await saveLabelled(source, quality: .hd1080, clipID: clipID)
        XCTAssertNil(again.renderStartedAt, "nothing rendered")
        XCTAssertEqual(savedAgain, saved)
    }

    func testChangingQualityLabelOrClipReplacesTheCopy() async throws {
        let source = try await makeSource(size: CGSize(width: 1280, height: 720))
        let clipID = UUID()
        let (_, first) = try await saveLabelled(source, quality: .hd1080, clipID: clipID)

        // Quality changed.
        let (_, full) = try await saveLabelled(source, quality: .full, clipID: clipID)
        XCTAssertNotEqual(full, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the old copy is removed")

        // Label text changed (team renamed, game edited).
        var renamed = label
        renamed.team = "Hawks"
        let share = ClipShareSession(clipID: clipID, source: source, label: renamed, quality: .full, sharer: Sharer())
        XCTAssertTrue(share.needsRender)
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.path), "stale copy removed on lookup")

        // Same clip, file rewritten (trim or new slow mo): a different source stamp.
        let (_, labelled) = try await saveLabelled(source, quality: .full, clipID: clipID)
        try await Task.sleep(for: .milliseconds(1100))
        try FileManager.default.removeItem(at: source)
        try await TestMedia.makeVideo(at: source, seconds: 3, fps: 30, size: CGSize(width: 1280, height: 720), gray: 100, withTone: true)
        let afterTrim = ClipShareSession(clipID: clipID, source: source, label: label, quality: .full, sharer: Sharer())
        XCTAssertTrue(afterTrim.needsRender)
        XCTAssertFalse(FileManager.default.fileExists(atPath: labelled.path))
        XCTAssertTrue(exportsFor(clipID).isEmpty)
    }

    func testDeletingTheClipRemovesItsCachedCopies() async throws {
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let game = Game(label: "", recordedAt: .now, videoFilename: "none.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
        context.insert(game)
        let clip = Clip(filename: "\(UUID().uuidString).mov", startSeconds: 0, endSeconds: 2, fileSize: 1)
        context.insert(clip)
        clip.game = game
        // The clip's own file, made where the app keeps clips; deleteClip removes it.
        try FileManager.default.copyItem(at: try await makeSource(size: CGSize(width: 1280, height: 720)), to: clip.fileURL)

        let (_, original) = try await saveLabelled(clip.fileURL, quality: .hd1080, clipID: clip.id)
        let (_, vertical) = try await saveLabelled(clip.fileURL, format: .vertical, quality: .hd1080, clipID: clip.id)
        XCTAssertEqual(exportsFor(clip.id).count, 2)

        StorageManager.deleteClip(clip, in: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vertical.path))
        XCTAssertTrue(exportsFor(clip.id).isEmpty)
    }

    func testDeletingTheGameRemovesItsClipsCachedCopies() async throws {
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let game = Game(label: "", recordedAt: .now, videoFilename: "\(UUID().uuidString).mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
        context.insert(game)
        let clip = Clip(filename: "\(UUID().uuidString).mov", startSeconds: 0, endSeconds: 2, fileSize: 1)
        context.insert(clip)
        clip.game = game
        try FileManager.default.copyItem(at: try await makeSource(size: CGSize(width: 1280, height: 720)), to: clip.fileURL)

        let (_, copy) = try await saveLabelled(clip.fileURL, quality: .hd1080, clipID: clip.id)
        StorageManager.deleteGame(game, in: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(exportsFor(clip.id).isEmpty)
    }

    func testLaunchCleanupRemovesCachedCopies() async throws {
        let source = try await makeSource(size: CGSize(width: 1280, height: 720))
        let clipID = UUID()
        let (_, copy) = try await saveLabelled(source, quality: .hd1080, clipID: clipID)
        let container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        StorageManager.performLaunchCleanup(in: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let share = ClipShareSession(clipID: clipID, source: source, label: label, quality: .hd1080, sharer: Sharer())
        XCTAssertTrue(share.needsRender, "a missing file is never offered")
    }

    func testCacheKeepsAtMostTheLimit() async throws {
        let source = try await makeSource(size: CGSize(width: 320, height: 180), seconds: 1)
        var copies: [URL] = []
        for _ in 0...LabelledExportCache.limit {
            copies.append(try await saveLabelled(source, quality: .hd1080).1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies[0].path), "oldest removed")
        XCTAssertTrue(copies.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testUnlabelledVerticalIsStillRemovedAfterSaving() async throws {
        let source = try await makeSource(size: CGSize(width: 320, height: 180), seconds: 1)
        let photos = Photos()
        let session = ClipExportSession(clipID: UUID(), source: source, label: nil, quality: .hd1080, photos: photos)
        session.export(.vertical)
        await session.finish()
        XCTAssertEqual(session.phase, .saved(.vertical))
        XCTAssertTrue(exportsFor(session.clipID).isEmpty, "not a labelled copy: not cached")
    }

    func testRenderShowsElapsedTimeFromItsStart() async throws {
        let source = try await makeSource(size: CGSize(width: 320, height: 180), seconds: 1)
        let before = Date.now
        let share = ClipShareSession(clipID: UUID(), source: source, label: label, quality: .hd1080, sharer: Sharer())
        XCTAssertNil(share.renderStartedAt)
        share.start()
        await share.finish()
        let started = try XCTUnwrap(share.renderStartedAt)
        XCTAssertGreaterThanOrEqual(started, before)
        XCTAssertLessThanOrEqual(started, .now)
    }

    // MARK: Helpers

    /// How much darker the label's corner is than the opposite corner, at 1 s (uniform gray source).
    private static func labelDarkening(_ url: URL, canvas: CGSize) async throws -> Double {
        let placement = LabelPlacement(canvas: canvas)
        let bottom = placement.origin.y + 2, top = placement.origin.y + placement.padding.height - 2
        let patch = CGRect(x: placement.origin.x + 2, y: canvas.height - top, width: placement.padding.width - 4, height: top - bottom)
        let far = patch.offsetBy(dx: canvas.width - patch.maxX - patch.minX, dy: -(canvas.height - top) + bottom)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func mean(_ rect: CGRect) -> Double {
            var sum = 0.0, count = 0.0
            for row in Int(rect.minY)..<Int(rect.maxY) {
                for column in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (row * width + column) * 4
                    sum += (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / (3 * 255)
                    count += 1
                }
            }
            return sum / max(count, 1)
        }
        return mean(far) - mean(patch)
    }
}

private final class Photos: PhotoLibrarySaving, @unchecked Sendable {
    var saved: [URL] = []
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws { saved.append(url) }
}

@MainActor
private final class Sharer: FileSharing {
    var shared: [URL] = []
    func share(_ url: URL) async { shared.append(url) }
}
