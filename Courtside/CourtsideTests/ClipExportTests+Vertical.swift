import AVFoundation
import CoreGraphics
import XCTest
@testable import Courtside

/// Vertical export: right size, right way up for every rotation phones store, a blurred background
/// instead of black bars, audio kept in step, and nothing left behind when cancelled.
final class VerticalExportTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func setUp() {
        StorageManager.prepareDirectories()
    }

    override func tearDown() {
        createdFiles.forEach(StorageManager.removeExport(at:))
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mov")
        createdFiles.append(url)
        return url
    }

    // MARK: Layout math

    func testLandscapeFillsTheWidthCentered() {
        let canvas = ExportFormat.verticalRenderSize
        XCTAssertEqual(VerticalLayout.foreground(videoSize: CGSize(width: 1920, height: 1080), canvas: canvas),
                       CGRect(x: 0, y: 656.25, width: 1080, height: 607.5))
        let background = VerticalLayout.background(videoSize: CGSize(width: 1920, height: 1080), canvas: canvas)
        XCTAssertEqual(background.height, 1920, accuracy: 0.01)
        XCTAssertEqual(background.midX, 540, accuracy: 0.01)
    }

    func testUprightVideoFillsTheFrame() {
        let canvas = ExportFormat.verticalRenderSize
        XCTAssertEqual(VerticalLayout.foreground(videoSize: CGSize(width: 2160, height: 3840), canvas: canvas),
                       CGRect(origin: .zero, size: canvas))
    }

    func testOriginalLabelNamesTheClipsRealShape() {
        XCTAssertEqual(ExportFormat.original.detail(sourceSize: CGSize(width: 3840, height: 2160)), "The clip as it is · 16:9")
        XCTAssertEqual(ExportFormat.original.detail(sourceSize: CGSize(width: 2160, height: 3840)), "The clip as it is · 9:16")
        XCTAssertEqual(ExportFormat.original.detail(sourceSize: CGSize(width: 1440, height: 1080)), "The clip as it is")
        XCTAssertEqual(ExportFormat.vertical.detail(sourceSize: nil), "For Instagram and TikTok · 9:16")
    }

    // MARK: Real exports

    /// One second of 320×180 frames, white in the stored top-left quarter, black elsewhere.
    private func makeCornerVideo(transform: CGAffineTransform) async throws -> URL {
        let url = tempURL("corner")
        let size = CGSize(width: 320, height: 180)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for row in 0..<Int(size.height) {
                for column in 0..<Int(size.width) {
                    let value: UInt8 = row < 90 && column < 160 ? 255 : 0
                    let offset = row * stride + column * 4
                    base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 20))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    /// A frame as an RGBA bitmap, with the track's rotation applied (what Photos shows).
    private func frame(of url: URL, at seconds: Double = 0.5) async throws -> (pixels: [UInt8], width: Int, height: Int) {
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
        return (pixels, width, height)
    }

    /// Brightness 0...1 at a point measured from the top-left.
    private func brightness(_ frame: (pixels: [UInt8], width: Int, height: Int), x: Double, y: Double) -> Double {
        let column = min(max(Int(x), 0), frame.width - 1)
        let row = min(max(Int(y), 0), frame.height - 1)
        return Double(frame.pixels[(row * frame.width + column) * 4]) / 255
    }

    /// Which quarter of `rect` (top-left origin) is bright: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private func brightQuarter(_ frame: (pixels: [UInt8], width: Int, height: Int), in rect: CGRect) -> Int? {
        let centers = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        let values = centers.map { brightness(frame, x: rect.minX + rect.width * $0.0, y: rect.minY + rect.height * $0.1) }
        let bright = values.indices.filter { values[$0] > 0.7 }
        let dark = values.indices.filter { values[$0] < 0.3 }
        return bright.count == 1 && dark.count == 3 ? bright[0] : nil
    }

    func testVerticalKeepsEveryRotationTheRightWayUp() async throws {
        let rotations: [(String, CGAffineTransform)] = [
            ("none", .identity),
            ("90 (phone upright)", CGAffineTransform(rotationAngle: .pi / 2)),
            ("-90 (DJI)", CGAffineTransform(rotationAngle: -.pi / 2)),
            ("180", CGAffineTransform(rotationAngle: .pi)),
        ]
        for (name, transform) in rotations {
            let source = try await makeCornerVideo(transform: transform)
            let shown = try await frame(of: source)
            let expected = try XCTUnwrap(brightQuarter(shown, in: CGRect(x: 0, y: 0, width: shown.width, height: shown.height)), name)

            let output = tempURL("vertical")
            try await ClipExtractor.exportForSharing(ExportPlan(source: source, format: .vertical), to: output) { _ in }
            let exported = try await frame(of: output)
            XCTAssertEqual(exported.width, 1080, name)
            XCTAssertEqual(exported.height, 1920, name)

            // Foreground rect, flipped from Core Image's bottom-left origin to the bitmap's top-left.
            let laidOut = VerticalLayout.foreground(videoSize: CGSize(width: shown.width, height: shown.height), canvas: ExportFormat.verticalRenderSize)
            let rect = CGRect(x: laidOut.minX, y: 1920 - laidOut.maxY, width: laidOut.width, height: laidOut.height)
            XCTAssertEqual(brightQuarter(exported, in: rect), expected, "\(name): same corner bright as Photos shows the source")
        }
    }

    func testLandscapeGetsABlurredBackgroundNotBlackBars() async throws {
        let source = try await makeCornerVideo(transform: .identity)
        let output = tempURL("vertical")
        try await ClipExtractor.exportForSharing(ExportPlan(source: source, format: .vertical), to: output) { _ in }
        let exported = try await frame(of: output)
        // Above the video is the frame scaled to fill: its white corner (left) meets black (right)
        // at x = 540. Not black bars: the left is bright. Blurred: the edge is soft, not a hard step.
        let row = 300.0
        XCTAssertGreaterThan(brightness(exported, x: 150, y: row), 0.5, "background above the video isn't a black bar")
        XCTAssertLessThan(brightness(exported, x: 950, y: row), 0.3)
        let step = brightness(exported, x: 528, y: row) - brightness(exported, x: 552, y: row)
        XCTAssertLessThan(step, 0.5, "edge across 24 px is soft (a sharp copy would jump ~0.9)")
        XCTAssertLessThan(brightness(exported, x: 150, y: row), 0.98, "background is slightly darkened")
    }

    func testAudioStaysInStepAndLengthIsKept() async throws {
        let source = tempURL("tone")
        try await TestMedia.makeVideo(at: source, seconds: 4, fps: 30, withTone: true)
        let output = tempURL("vertical")
        try await ClipExtractor.exportForSharing(ExportPlan(source: source, format: .vertical), to: output) { _ in }

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first, "audio kept")
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(videoRange.start.seconds, 0, accuracy: 0.05)
        XCTAssertEqual(audioRange.start.seconds, 0, accuracy: 0.05, "audio starts with the video")
        XCTAssertEqual(videoRange.duration.seconds, 4, accuracy: 0.1)
        XCTAssertEqual(audioRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.1)
        // The tone is still there in the middle.
        let level = try await TestMedia.audioLevel(of: output, from: 1.5, to: 2.5)
        XCTAssertGreaterThan(level, 0.01)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
    }

    func testCancelLeavesNoFiles() async throws {
        let source = tempURL("long")
        try await TestMedia.makeVideo(at: source, seconds: 20, fps: 30, withTone: true)
        let output = StorageManager.makeExportURL(clipID: UUID(), format: .vertical)
        createdFiles.append(output)

        let task = Task {
            try await ClipExtractor.exportForSharing(ExportPlan(source: source, format: .vertical), to: output) { _ in }
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected the export to be cancelled")
        } catch is CancellationError {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: StorageManager.partialURL(for: output).path))
    }
}
