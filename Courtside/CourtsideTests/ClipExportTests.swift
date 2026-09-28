import AVFoundation
import XCTest
@testable import Courtside

/// Exercises the real export path against a generated, rotated source video.
final class ClipExportTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        StorageManager.prepareDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testExportIsFrameAccurateAndKeepsRotation() async throws {
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let source = workDirectory.appending(path: "source.mov")
        try await Self.writeTestVideo(to: source, seconds: 30, transform: rotation)

        let destination = workDirectory.appending(path: "clip.mov")
        let window = ClipWindow.around(mark: 20, preRoll: 10, postRoll: 3, gameDuration: 30)
        try await ClipExtractor.export(source: source, window: window, to: destination) { _ in }

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 13, accuracy: 0.1)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        XCTAssertEqual(transform.a, rotation.a, accuracy: 0.001)
        XCTAssertEqual(transform.b, rotation.b, accuracy: 0.001)
        XCTAssertEqual(transform.c, rotation.c, accuracy: 0.001)
        XCTAssertEqual(transform.d, rotation.d, accuracy: 0.001)

        // The clip's first frame should match source frame 300 (t=10s). Gray levels drift a
        // little through two lossy encodes, so find the closest-matching source frame nearby.
        let clipLevel = try await Self.grayLevel(in: destination, at: 0)
        var best = (frame: -1, difference: Int.max)
        for frame in (10 * Self.fps - 15)...(10 * Self.fps + 15) {
            let level = try await Self.grayLevel(in: source, at: Double(frame) / Double(Self.fps))
            let difference = abs(level - clipLevel)
            if difference < best.difference { best = (frame, difference) }
        }
        XCTAssertEqual(best.frame, 10 * Self.fps, accuracy: 1)

        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.partialURL(for: destination)))
    }

    func testExportReplacesExistingFile() async throws {
        let source = workDirectory.appending(path: "source.mov")
        try await Self.writeTestVideo(to: source, seconds: 20, transform: .identity)
        let destination = workDirectory.appending(path: "clip.mov")

        try await ClipExtractor.export(source: source, window: ClipWindow(start: 2, end: 12), to: destination) { _ in }
        try await ClipExtractor.export(source: source, window: ClipWindow(start: 3, end: 8), to: destination) { _ in }

        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 5, accuracy: 0.1)
    }

    // MARK: Fixtures

    private static let fps = 30
    private static let size = CGSize(width: 320, height: 180)

    /// Gray level steps by 8 per frame (period 32 frames) so neighboring frames are easy to tell apart.
    private static func writeTestVideo(to url: URL, seconds: Int, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 60],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let level = UInt8(truncatingIfNeeded: frame * 8)
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(level), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    /// Decodes the frame at `seconds` and returns its gray level.
    private static func grayLevel(in url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0])
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) is not within \(accuracy) of \(b)", file: file, line: line)
}
