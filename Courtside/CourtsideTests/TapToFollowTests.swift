import AVFoundation
import XCTest
@testable import Courtside

/// Tap-to-follow spike (decision 0027): snapping, crop smoothing, the results log, and the tracker
/// on generated video (a textured block moving across the frame, upright and rotated).
final class TapToFollowTests: XCTestCase {
    // MARK: Snapping the tap

    func testTapInsideABodySnapsToIt() {
        let a = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.3)
        let b = CGRect(x: 0.5, y: 0.2, width: 0.1, height: 0.3)
        XCTAssertEqual(TapToFollowTracker.snap(tap: CGPoint(x: 0.55, y: 0.3), to: [a, b]), b)
    }

    func testOverlappingBodiesPickTheSmallerOne() {
        let near = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.5)
        let far = CGRect(x: 0.45, y: 0.25, width: 0.06, height: 0.15)
        XCTAssertEqual(TapToFollowTracker.snap(tap: CGPoint(x: 0.47, y: 0.3), to: [near, far]), far)
    }

    func testTapNearABodySnapsAndFarTapDoesNot() {
        let body = CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.1)
        XCTAssertEqual(TapToFollowTracker.snap(tap: CGPoint(x: 0.48, y: 0.5), to: [body]), body)
        XCTAssertNil(TapToFollowTracker.snap(tap: CGPoint(x: 0.1, y: 0.1), to: [body]))
        XCTAssertNil(TapToFollowTracker.snap(tap: CGPoint(x: 0.5, y: 0.5), to: []))
    }

    func testFallbackBoxIsUpperBodyShapedAndInsideTheFrame() {
        let box = TapToFollowTracker.fallbackBox(around: CGPoint(x: 0.5, y: 0.5), displaySize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(box.height, 0.1, accuracy: 0.001)
        XCTAssertEqual(box.width * 1920 / (box.height * 1080), 1 / 1.5, accuracy: 0.01, "1 : 1.5 in pixels")
        XCTAssertEqual(box.midX, 0.5, accuracy: 0.001)
        let corner = TapToFollowTracker.fallbackBox(around: CGPoint(x: 0, y: 0), displaySize: CGSize(width: 1920, height: 1080))
        XCTAssertGreaterThanOrEqual(corner.minX, 0)
        XCTAssertGreaterThanOrEqual(corner.minY, 0)
    }

    func testResnapNeedsEnoughOverlap() {
        let tracked = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.2)
        let same = CGRect(x: 0.51, y: 0.5, width: 0.1, height: 0.2)
        let neighbour = CGRect(x: 0.58, y: 0.5, width: 0.1, height: 0.2)
        XCTAssertEqual(TapToFollowTracker.bestOverlap(for: tracked, among: [neighbour, same]), same)
        XCTAssertNil(TapToFollowTracker.bestOverlap(for: tracked, among: [neighbour]), "a neighbour barely touching doesn't take over")
        XCTAssertEqual(TapToFollowTracker.overlap(tracked, tracked), 1, accuracy: 0.0001)
        XCTAssertEqual(TapToFollowTracker.overlap(tracked, CGRect(x: 0, y: 0, width: 0.1, height: 0.1)), 0)
    }

    func testOrientationFromRotation() {
        XCTAssertEqual(TapToFollowTracker.imageOrientation(for: .identity), .up)
        XCTAssertEqual(TapToFollowTracker.imageOrientation(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .right)
        XCTAssertEqual(TapToFollowTracker.imageOrientation(for: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .left)
        XCTAssertEqual(TapToFollowTracker.imageOrientation(for: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .down)
    }

    func testVisionRectsFlipVertically() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(TapToFollowTracker.topLeftRect(rect).minY, 0.4, accuracy: 0.0001)
        let back = TapToFollowTracker.visionRect(TapToFollowTracker.topLeftRect(rect))
        XCTAssertEqual(back.minY, rect.minY, accuracy: 0.0001)
    }

    func testSampleLookup() {
        let samples = (0..<10).map { FollowSample(time: Double($0) / 10, box: .zero, confidence: 1, resnapped: false) }
        let track = FollowTrack(samples: samples, mode: .trackerOnly, processingSeconds: 1, videoSeconds: 1, trackedFPS: 10, displaySize: .zero)
        XCTAssertEqual(track.sample(at: -1)?.time, 0)
        XCTAssertEqual(track.sample(at: 0.35)?.time ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(track.sample(at: 5)?.time ?? -1, 0.9, accuracy: 0.0001)
    }

    // MARK: 9:16 follow window

    func testWindowWidth() {
        XCTAssertEqual(FollowCrop.windowWidth(displaySize: CGSize(width: 1920, height: 1080)), 0.3164, accuracy: 0.001)
        XCTAssertEqual(FollowCrop.windowWidth(displaySize: CGSize(width: 1080, height: 1920)), 1, "portrait needs no following")
    }

    func testSmoothingRemovesJitterAndStaysInsideTheFrame() {
        let times = (0..<120).map { Double($0) / 30 }
        // Player at 0.5 with ±0.03 frame-to-frame box jitter.
        let jittery = times.indices.map { 0.5 + ($0 % 2 == 0 ? 0.03 : -0.03) }
        let smooth = FollowCrop.smoothedCenters(times: times, xs: jittery, windowWidth: 0.32)
        XCTAssertEqual(smooth.count, times.count)
        let wobble = zip(smooth.dropFirst(), smooth).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(wobble, 0.005)
        // A player at the edge keeps the window inside the frame.
        let edge = FollowCrop.smoothedCenters(times: times, xs: times.map { _ in 0.02 }, windowWidth: 0.32)
        XCTAssertEqual(edge.min() ?? 0, 0.16, accuracy: 0.0001)
    }

    func testSmoothingFollowsAMoveWithoutLagAtTheMiddle() {
        let times = (0..<180).map { Double($0) / 30 }
        let step = times.map { $0 < 3 ? 0.3 : 0.7 }
        let smooth = FollowCrop.smoothedCenters(times: times, xs: step, windowWidth: 0.32)
        XCTAssertEqual(smooth[90], 0.5, accuracy: 0.05, "zero-phase: halfway at the moment of the move")
        XCTAssertEqual(smooth.first ?? 0, 0.3, accuracy: 0.01)
        XCTAssertEqual(smooth.last ?? 0, 0.7, accuracy: 0.01)
    }

    func testFitted() {
        let rect = FollowCrop.fitted(CGSize(width: 16, height: 9), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect.width, 400)
        XCTAssertEqual(rect.height, 225)
        XCTAssertEqual(rect.minY, 87.5)
    }

    // MARK: Results log

    func testLogAppendsAndSummarisesLatestPerClip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "follow-log-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = TapToFollowLog(url: folder.appending(path: "log.jsonl"))
        XCTAssertFalse(log.exists)
        XCTAssertEqual(log.verdicts(), [])
        let a = UUID(), b = UUID()
        try log.append(verdict(a, .lost, at: 1, note: "Switched to a player who crossed in front"))
        try log.append(verdict(a, .stayed, at: 2))
        try log.append(verdict(b, .lost, at: 3))
        let all = log.verdicts()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].failureNote, "Switched to a player who crossed in front")
        let summary = FollowSummary(all)
        XCTAssertEqual(summary.clips, 2)
        XCTAssertEqual(summary.stayed, 1)
        XCTAssertEqual(summary.latest[a], .stayed, "a re-test replaces the clip's earlier verdict")
        XCTAssertEqual(summary.rate ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertNil(FollowSummary([]).rate)
    }

    private func verdict(_ clip: UUID, _ result: FollowVerdict.Result, at seconds: Double, note: String? = nil) -> FollowVerdict {
        FollowVerdict(date: Date(timeIntervalSince1970: seconds), clipID: clip, result: result, failureNote: note, scene: .crowdedPaint,
                      mode: .trackerWithResnap, processingSeconds: 2, clipSeconds: 13, videoSize: "1920x1080", trackedFPS: 30,
                      framesTracked: 390, resnaps: 40, trackerRestarts: 0, lowConfidenceFrames: 3, minConfidence: 0.2, meanConfidence: 0.8,
                      tapSnappedToBody: true, device: "test")
    }

    // MARK: Tracking generated video

    func testTracksAMovingBlockUpright() async throws {
        try await checkTracking(rotated: false)
    }

    func testTracksAMovingBlockInARotatedVideo() async throws {
        try await checkTracking(rotated: true)
    }

    /// A textured block moves left to right across a 1280×720 frame over 3 s (stored), vertically
    /// centred. Rotated 90°, it shows moving top to bottom in a 720×1280 picture.
    private func checkTracking(rotated: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "follow-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 1280, height: 720), block = CGSize(width: 80, height: 160)
        let transform = rotated ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0) : .identity
        let startX = 0.2, endX = 0.7, frames = 90
        try await writeMovingBlock(to: url, size: size, block: block, frames: frames, transform: transform) { frame in
            startX + (endX - startX) * Double(frame) / Double(frames - 1)
        }
        func expected(_ t: Double) -> CGPoint {
            let x = startX + (endX - startX) * min(t * 30 / Double(frames - 1), 1)
            return rotated ? CGPoint(x: 0.5, y: x) : CGPoint(x: x, y: 0.5)
        }
        let width = block.width / size.width, height = block.height / size.height
        let first = expected(0)
        let start = rotated
            ? CGRect(x: first.x - height / 2, y: first.y - width / 2, width: height, height: width)
            : CGRect(x: first.x - width / 2, y: first.y - height / 2, width: width, height: height)

        for mode in FollowMode.allCases {
            let track = try await TapToFollowTracker.track(url: url, from: start, mode: mode)
            XCTAssertEqual(track.samples.count, frames, "\(mode)")
            XCTAssertEqual(track.trackedFPS, 30, accuracy: 0.5)
            XCTAssertEqual(track.displaySize, rotated ? CGSize(width: 720, height: 1280) : size)
            for sample in track.samples {
                let want = expected(sample.time)
                XCTAssertEqual(sample.box.midX, want.x, accuracy: 0.05, "\(mode) x at \(sample.time)")
                XCTAssertEqual(sample.box.midY, want.y, accuracy: 0.05, "\(mode) y at \(sample.time)")
            }
        }
    }

    private func writeMovingBlock(
        to url: URL, size: CGSize, block: CGSize, frames: Int, transform: CGAffineTransform, x: (Int) -> Double
    ) async throws {
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
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            context.setFillColor(gray: 0.45, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            // Checkered block, vertically centred (so CG's bottom-left origin doesn't matter).
            let origin = CGPoint(x: x(frame) * size.width - block.width / 2, y: (size.height - block.height) / 2)
            let tile: CGFloat = 16
            for row in 0..<Int(block.height / tile) {
                for column in 0..<Int(block.width / tile) {
                    context.setFillColor(gray: (row + column) % 2 == 0 ? 0.05 : 0.95, alpha: 1)
                    context.fill(CGRect(x: origin.x + CGFloat(column) * tile, y: origin.y + CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
