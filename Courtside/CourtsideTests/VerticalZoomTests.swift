import AVFoundation
import XCTest
@testable import Courtside

/// Zoom and aim for Vertical exports of landscape clips (decision 0024): the crop-window math, the
/// sheet's session, the labelled-copy cache, and frames sampled from real exports.
@MainActor
final class VerticalZoomTests: XCTestCase {
    private static let uhd = CGSize(width: 3840, height: 2160)
    private static let hd = CGSize(width: 1920, height: 1080)
    private static let canvas = ExportFormat.verticalRenderSize
    private let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)
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

    // MARK: Crop-window math

    func testZoomLimitsFollowTheUpscaleCap() {
        XCTAssertEqual(VerticalFraming.maxZoom(videoSize: Self.uhd), 1, "4K fills the frame without stretching")
        // 1080p: fit 0.5625, fill 1.778, cap 1.5 → (1.5 − 0.5625) / (1.778 − 0.5625).
        XCTAssertEqual(VerticalFraming.maxZoom(videoSize: Self.hd), 0.771, accuracy: 0.002)
        XCTAssertEqual(VerticalFraming.maxZoom(videoSize: CGSize(width: 1280, height: 720)), 0.362, accuracy: 0.002)
        XCTAssertEqual(VerticalFraming.maxZoom(videoSize: CGSize(width: 320, height: 180)), 0, "even fitting the width stretches it")
        for size in [Self.uhd, Self.hd, CGSize(width: 1280, height: 720)] {
            let top = VerticalFraming.maxZoom(videoSize: size)
            XCTAssertLessThanOrEqual(VerticalFraming.scale(zoom: top, videoSize: size), VerticalFraming.maxUpscale + 0.0001)
        }
    }

    func testZoomZeroIsTodaysLayoutAndZoomOneFillsTheFrame() {
        for size in [Self.uhd, Self.hd] {
            let fit = VerticalFraming(zoom: 0).foreground(videoSize: size)
            let today = VerticalLayout.foreground(videoSize: size, canvas: Self.canvas)
            XCTAssertEqual(fit.minX, today.minX, accuracy: 0.01)
            XCTAssertEqual(fit.minY, today.minY, accuracy: 0.01)
            XCTAssertEqual(fit.width, today.width, accuracy: 0.01)
            XCTAssertEqual(fit.height, today.height, accuracy: 0.01)
        }
        let fill = VerticalFraming(zoom: 1).foreground(videoSize: Self.uhd)
        XCTAssertEqual(fill.height, 1920, accuracy: 0.01)
        XCTAssertEqual(fill.midX, 540, accuracy: 0.01, "centered")
        XCTAssertTrue(fill.minX < 0 && fill.maxX > 1080, "sides cropped")
    }

    func testWindowIsCenteredByDefault() {
        let window = VerticalFraming(zoom: 0.6).window(videoSize: Self.uhd)
        XCTAssertEqual(window.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(window.midY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(window.width / window.height, (9.0 / 16) / (16.0 / 9), accuracy: 0.001, "9:16 in video pixels")
        let full = VerticalFraming(zoom: 1).window(videoSize: Self.uhd)
        XCTAssertEqual(full.height, 1, accuracy: 0.0001)
        XCTAssertEqual(full.width, 1215.0 / 3840, accuracy: 0.001)
        let zero = VerticalFraming(zoom: 0).window(videoSize: Self.uhd)
        XCTAssertEqual(zero.width, 1, accuracy: 0.0001, "full width")
        XCTAssertGreaterThan(zero.height, 1, "taller than the video: blurred above and below")
    }

    func testAimIsClampedInsideTheVideo() {
        let left = VerticalFraming(zoom: 1, center: CGPoint(x: -1, y: 0.1)).clamped(videoSize: Self.uhd)
        let half = 1215.0 / 3840 / 2
        XCTAssertEqual(left.center.x, half, accuracy: 0.001)
        XCTAssertEqual(left.center.y, 0.5, accuracy: 0.0001, "no room up or down at full height")
        XCTAssertEqual(VerticalFraming(zoom: 1, center: CGPoint(x: 0, y: 0.5)).foreground(videoSize: Self.uhd).minX, 0, accuracy: 0.01)
        let right = VerticalFraming(zoom: 1).moved(by: CGSize(width: 2, height: 0), videoSize: Self.uhd)
        XCTAssertEqual(right.center.x, 1 - half, accuracy: 0.001)
        XCTAssertEqual(VerticalFraming(zoom: 1, center: CGPoint(x: 1, y: 0.5)).foreground(videoSize: Self.uhd).maxX, 1080, accuracy: 0.01)
        let zero = VerticalFraming(zoom: 0, center: CGPoint(x: 0.1, y: 0.9)).clamped(videoSize: Self.uhd)
        XCTAssertEqual(zero.center, CGPoint(x: 0.5, y: 0.5), "zoom 0 shows the whole width: nothing to aim")
        XCTAssertEqual(VerticalFraming(zoom: 1).clamped(videoSize: Self.hd).zoom, VerticalFraming.maxZoom(videoSize: Self.hd), accuracy: 0.0001)
    }

    func testNoUpAndDownAimWhileTheWholeHeightShows() {
        // Zoom 1 is exactly the video's full height, so there's never room to aim up or down
        // within the slider's range; the window stays centered vertically.
        for zoom in [0.0, 0.3, 0.6, 1.0] {
            let framing = VerticalFraming(zoom: zoom, center: CGPoint(x: 0.5, y: 0)).clamped(videoSize: Self.uhd)
            XCTAssertEqual(framing.center.y, 0.5, accuracy: 0.0001)
        }
    }

    func testPortraitClipsAreNotFramed() {
        XCTAssertFalse(VerticalFraming.applies(to: CGSize(width: 2160, height: 3840)))
        XCTAssertFalse(VerticalFraming.applies(to: CGSize(width: 1080, height: 1080)))
        XCTAssertTrue(VerticalFraming.applies(to: Self.hd))
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        XCTAssertNil(ExportPlan(source: url, format: .original, label: nil, framing: VerticalFraming(zoom: 1)).verticalFraming)
        XCTAssertEqual(ExportPlan(source: url, format: .vertical, label: nil, framing: VerticalFraming(zoom: 1)).verticalFraming?.zoom, 1)
    }

    func testLastZoomDefaultsTo60() {
        UserDefaults.standard.removeObject(forKey: VerticalZoomSettings.lastZoomKey)
        XCTAssertEqual(VerticalZoomSettings.lastZoom, 0.6)
        VerticalZoomSettings.lastZoom = 0.25
        XCTAssertEqual(VerticalZoomSettings.lastZoom, 0.25)
    }

    // MARK: The sheet's session

    func testLandscapeClipAsksForZoomAndPortraitDoesNot() async throws {
        UserDefaults.standard.removeObject(forKey: VerticalZoomSettings.lastZoomKey)
        let landscape = ClipExportSession(clipID: UUID(), source: try await makeBanded(size: Self.hd), photos: Photos())
        await landscape.load()
        XCTAssertTrue(landscape.canFrame)
        XCTAssertNotNil(landscape.previewFrame)
        XCTAssertEqual(landscape.framing.zoom, 0.6, "default 60 %, centered")
        XCTAssertEqual(landscape.framing.center, CGPoint(x: 0.5, y: 0.5))
        landscape.choose(.vertical)
        XCTAssertEqual(landscape.phase, .framing)
        landscape.cancelFraming()
        XCTAssertEqual(landscape.phase, .choosing)

        landscape.setZoom(1)
        XCTAssertEqual(landscape.framing.zoom, landscape.maxZoom, accuracy: 0.0001, "1080p stops short of full fill")
        XCTAssertTrue(landscape.isZoomLimited)
        landscape.setZoom(0.5)
        XCTAssertFalse(landscape.isZoomLimited)

        let portrait = ClipExportSession(clipID: UUID(), source: try await makeBanded(size: CGSize(width: 1080, height: 1920)), photos: Photos())
        await portrait.load()
        XCTAssertFalse(portrait.canFrame)
        XCTAssertNil(portrait.previewFrame)
        portrait.choose(.vertical)
        XCTAssertNotEqual(portrait.phase, .framing, "portrait clips export straight away, as before")
        await portrait.finish()
    }

    func testSavingRemembersTheZoom() async throws {
        let photos = Photos()
        let session = ClipExportSession(clipID: UUID(), source: try await makeBanded(size: Self.hd, seconds: 1), photos: photos)
        await session.load()
        session.setZoom(0.3)
        session.export(.vertical)
        await session.finish()
        XCTAssertEqual(session.phase, .saved(.vertical))
        XCTAssertEqual(VerticalZoomSettings.lastZoom, 0.3, accuracy: 0.0001)
        let next = ClipExportSession(clipID: UUID(), source: session.source, photos: photos)
        await next.load()
        XCTAssertEqual(next.framing.zoom, 0.3, accuracy: 0.0001, "next default")
    }

    func testShareStillUsesOriginal() async throws {
        let share = ClipShareSession(clipID: UUID(), source: try await makeBanded(size: Self.hd, seconds: 1), label: label, sharer: Sharer())
        XCTAssertEqual(share.plan.format, .original)
        XCTAssertNil(share.plan.verticalFraming)
    }

    // MARK: Cache

    func testCachedCopiesAreKeyedByZoomAndAim() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "zoom-key-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        files.append(url)
        let clipID = UUID()
        func key(_ framing: VerticalFraming?) -> LabelledExportCache.Key {
            .init(clipID: clipID, source: .init(url), format: .vertical, label: label, quality: .hd1080, framing: framing)
        }
        XCTAssertEqual(key(VerticalFraming(zoom: 0.6)), key(VerticalFraming(zoom: 0.6000001)), "same look, same copy")
        XCTAssertNotEqual(key(VerticalFraming(zoom: 0.6)), key(VerticalFraming(zoom: 0.7)))
        XCTAssertNotEqual(key(VerticalFraming(zoom: 1, center: CGPoint(x: 0.3, y: 0.5))), key(VerticalFraming(zoom: 1)))

        let copy = StorageManager.makeExportURL(clipID: clipID, format: .vertical)
        FileManager.default.createFile(atPath: copy.path, contents: Data([2]))
        LabelledExportCache.shared.store(copy, for: key(VerticalFraming(zoom: 0.6)))
        XCTAssertEqual(LabelledExportCache.shared.file(for: key(VerticalFraming(zoom: 0.6))), copy)
        XCTAssertNil(LabelledExportCache.shared.file(for: key(VerticalFraming(zoom: 0.8))), "a different zoom makes a new copy")
        XCTAssertFalse(StorageManager.fileExists(at: copy), "the stale copy is removed")
    }

    // MARK: Exported frames

    func test4KFramesShowTheRightRegion() async throws {
        let source = try await makeBanded(size: Self.uhd)
        for zoom in [0.0, 0.6, 1.0] {
            try await checkRegion(source: source, size: Self.uhd, framing: VerticalFraming(zoom: zoom))
        }
        try await checkRegion(source: source, size: Self.uhd, framing: VerticalFraming(zoom: 1, center: CGPoint(x: 0, y: 0.5)))
    }

    func test1080pFramesShowTheRightRegionAndStopAtTheCap() async throws {
        let source = try await makeBanded(size: Self.hd)
        for zoom in [0.0, 0.6, 1.0] {
            try await checkRegion(source: source, size: Self.hd, framing: VerticalFraming(zoom: zoom))
        }
    }

    func testFullZoomHasNoBlurredBands() async throws {
        let source = try await makeBanded(size: Self.uhd)
        let output = try await export(source, framing: VerticalFraming(zoom: 1))
        let frame = try await Frame(of: output, at: 1)
        // Top and bottom rows are the video's own bands, not blur: same level as the middle.
        for x in [100, 540, 980] {
            XCTAssertEqual(frame.gray(x: x, y: 30), frame.gray(x: x, y: 960), accuracy: 12, "x \(x)")
            XCTAssertEqual(frame.gray(x: x, y: 1890), frame.gray(x: x, y: 960), accuracy: 12, "x \(x)")
        }
    }

    func testPortraitSourceKeepsTodaysVertical() async throws {
        let source = try await makeBanded(size: CGSize(width: 1080, height: 1920))
        let framed = try await Frame(of: try await export(source, framing: VerticalFraming(zoom: 1, center: CGPoint(x: 0, y: 0.5))), at: 1)
        let today = try await Frame(of: try await export(source, framing: nil), at: 1)
        for x in stride(from: 40, to: 1080, by: 100) {
            XCTAssertEqual(framed.gray(x: x, y: 960), today.gray(x: x, y: 960), accuracy: 6)
        }
    }

    func testLabelStaysInTheSafeAreaOverTheVideo() async throws {
        let box = try XCTUnwrap(LabelRenderer.image(for: label, canvas: Self.canvas)).extent
        // Lower-left, above the bottom fifth where Instagram and TikTok put captions, and clear of
        // their buttons on the right.
        XCTAssertGreaterThanOrEqual(box.minX, 1080 * 0.05)
        XCTAssertLessThanOrEqual(box.maxX, 1080 * 0.76)
        XCTAssertGreaterThanOrEqual(box.minY, 1920 * 0.20)
        XCTAssertLessThanOrEqual(box.maxY, 1920 * 0.50)

        let source = try await makeBanded(size: Self.uhd, seconds: 4)
        for zoom in [0.0, 0.6, 1.0] {
            let framing = VerticalFraming(zoom: zoom)
            let labelled = try await Frame(of: try await export(source, framing: framing, label: label), at: 1)
            let plain = try await Frame(of: try await export(source, framing: framing), at: 1)
            // In the box's left padding at mid-height (clear of the text and the rounded corners):
            // darker with the label than without.
            let x = Int(box.minX) + 10, y = 1920 - Int(box.midY)
            XCTAssertLessThan(labelled.gray(x: x, y: y), plain.gray(x: x, y: y) * 0.8, "zoom \(zoom): dark box drawn")
            let foreground = framing.foreground(videoSize: Self.uhd)
            let overVideo = box.minY >= foreground.minY && box.maxY <= foreground.maxY
            XCTAssertEqual(overVideo, zoom > 0, "zoom \(zoom): over the video when zoomed, in the blur at 0")
        }
    }

    func testSlowMoClipCanBeFramed() async throws {
        let clip = try await makeBanded(size: Self.uhd, seconds: 2, fps: 30)
        let slowMo = FileManager.default.temporaryDirectory.appending(path: "zoom-slowmo-\(UUID().uuidString).mov")
        files.append(slowMo)
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: SlowMoSegment(start: 0.5, end: 1.5), speed: .half, to: slowMo) { _ in }
        let output = try await export(slowMo, framing: VerticalFraming(zoom: 1))
        let size = try await SlowMoComposer.displaySize(of: output)
        XCTAssertEqual(size, Self.canvas)
        let lengths = (try await AVURLAsset(url: output).load(.duration).seconds, try await AVURLAsset(url: slowMo).load(.duration).seconds)
        XCTAssertEqual(lengths.0, lengths.1, accuracy: 0.15)
    }

    // MARK: Helpers

    /// Checks the 1080×1920 output at `framing` shows the bands the window covers.
    private func checkRegion(source: URL, size: CGSize, framing: VerticalFraming) async throws {
        let output = try await export(source, framing: framing)
        let outputSize = try await SlowMoComposer.displaySize(of: output)
        XCTAssertEqual(outputSize, Self.canvas)
        let frame = try await Frame(of: output, at: 1)
        // Each band's level as the source itself decodes (encoding shifts levels a little).
        let sourceFrame = try await Frame(of: source, at: 1)
        let levels = (0..<Self.bands).map { band in
            sourceFrame.gray(x: Int((Double(band) + 0.5) / Double(Self.bands) * Double(sourceFrame.width)), y: sourceFrame.height / 2)
        }
        let foreground = framing.foreground(videoSize: size)
        let bandWidth = size.width / CGFloat(Self.bands)
        var checked = 0
        for x in stride(from: 10, to: 1070, by: 20) {
            let sourceX = (CGFloat(x) - foreground.minX) / foreground.width * size.width
            let band = Int(sourceX / bandWidth)
            let offset = sourceX / bandWidth - CGFloat(band)
            // Band centers only: edges blend in the encoder.
            guard band >= 0, band < Self.bands, offset > 0.25, offset < 0.75 else { continue }
            XCTAssertEqual(frame.gray(x: x, y: 960), levels[band], accuracy: 8, "zoom \(framing.zoom) center \(framing.center.x): x \(x) should show band \(band)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 4)
    }

    private func export(_ source: URL, framing: VerticalFraming?, label: LabelStep.LabelText? = nil) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "zoom-out-\(UUID().uuidString).mov")
        files.append(output)
        let plan = ExportPlan(source: source, format: .vertical, label: label, quality: .hd1080, framing: framing)
        try await ClipExtractor.exportForSharing(plan, to: output) { _ in }
        return output
    }

    private static let bands = 8
    /// Gray level of band `index`, far enough apart to tell after compression.
    private static func level(_ index: Int) -> Double { Double(16 + index * 30) }

    /// A video of 8 vertical gray bands, darkest on the left, so a frame's columns show which part
    /// of the source they came from.
    private func makeBanded(size: CGSize, seconds: Int = 2, fps: Int = 10) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "zoom-src-\(UUID().uuidString).mov")
        files.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let width = Int(size.width), height = Int(size.height)
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            var row = [UInt8](repeating: 255, count: width * 4)
            for x in 0..<width {
                let value = UInt8(Self.level(min(Self.bands - 1, x * Self.bands / width)))
                row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value
            }
            for y in 0..<height {
                row.withUnsafeBytes { (base + y * rowBytes).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    /// One decoded frame, readable as gray levels at top-left pixel coordinates.
    private struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(of url: URL, at seconds: Double) async throws {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.bytes = bytes
        }

        /// Average of R, G and B at (x, y), y from the top.
        func gray(x: Int, y: Int) -> Double {
            let i = (y * width + x) * 4
            return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
        }
    }
}

private final class Photos: PhotoLibrarySaving, @unchecked Sendable {
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws {}
}

@MainActor
private final class Sharer: FileSharing {
    func share(_ url: URL) async {}
}
