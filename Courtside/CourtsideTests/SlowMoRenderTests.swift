import AVFoundation
import XCTest
@testable import Courtside

/// Renders real slow-motion files from generated clips and checks the output.
final class SlowMoRenderTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        StorageManager.prepareDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func testClipExportKeepsSixtyFps() async throws {
        let source = work.appending(path: "source.mov")
        try await TestMedia.makeVideo(at: source, seconds: 6, fps: 60, withTone: false)
        let clip = work.appending(path: "clip.mov")
        try await ClipExtractor.export(source: source, window: ClipWindow(start: 1, end: 5), to: clip) { _ in }
        let fps = try await SlowMoComposer.videoFrameRate(of: clip)
        XCTAssertEqual(fps, 60, accuracy: 1, "slow-mo availability depends on clips keeping the source frame rate")
    }

    func testQuarterSpeedRenderDurationRotationAndAudio() async throws {
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let clip = work.appending(path: "clip.mov")
        try await TestMedia.makeVideo(at: clip, seconds: 8, fps: 60, transform: rotation, withTone: true)

        let segment = SlowMoSegment(start: 3, end: 4.5)
        let output = work.appending(path: "slow.mov")
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: segment, speed: .quarter, to: output) { _ in }

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        // 8 - 1.5 + 1.5 / 0.25 = 12.5
        XCTAssertEqual(duration, 12.5, accuracy: 0.1)

        let transform = try await asset.loadTracks(withMediaType: .video)[0].load(.preferredTransform)
        XCTAssertEqual(transform.b, rotation.b, accuracy: 0.001, "portrait/rotated footage must not render sideways")
        XCTAssertEqual(transform.c, rotation.c, accuracy: 0.001)

        // Audio: normal [0, 3), silent through the 6 s stretched segment [3, 9), normal [9, 12.5).
        let before = try await TestMedia.audioLevel(of: output, from: 0.5, to: 2.5)
        let during = try await TestMedia.audioLevel(of: output, from: 3.5, to: 8.5)
        let after = try await TestMedia.audioLevel(of: output, from: 9.5, to: 12)
        XCTAssertGreaterThan(before, 0.1)
        XCTAssertLessThan(during, 0.01)
        XCTAssertGreaterThan(after, 0.1)

        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.partialURL(for: output)))
    }

    func testHalfSpeedSegmentAtClipEdges() async throws {
        let clip = work.appending(path: "clip.mov")
        try await TestMedia.makeVideo(at: clip, seconds: 6, fps: 30, withTone: true)

        // Slow segment touching the start, then touching the end: the audio gap must still be contiguous.
        let atStart = work.appending(path: "start.mov")
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: SlowMoSegment(start: 0, end: 2), speed: .half, to: atStart) { _ in }
        let startDuration = try await AVURLAsset(url: atStart).load(.duration).seconds
        XCTAssertEqual(startDuration, 8, accuracy: 0.1)

        let atEnd = work.appending(path: "end.mov")
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: SlowMoSegment(start: 4, end: 6), speed: .half, to: atEnd) { _ in }
        let endDuration = try await AVURLAsset(url: atEnd).load(.duration).seconds
        XCTAssertEqual(endDuration, 8, accuracy: 0.1)
    }

    func testWholeClipSlowedWhenShorterThanSegment() async throws {
        let clip = work.appending(path: "clip.mov")
        try await TestMedia.makeVideo(at: clip, seconds: 3, fps: 60, withTone: false)
        let segment = SlowMotion.defaultSegment(markInClip: 1, clipDuration: 3)
        let output = work.appending(path: "slow.mov")
        try await ClipExtractor.exportSlowMo(clipURL: clip, segment: segment, speed: .half, to: output) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.1)
    }

    func testFrameRateIsReadFromVideoTrack() async throws {
        let clip = work.appending(path: "clip.mov")
        try await TestMedia.makeVideo(at: clip, seconds: 2, fps: 24, withTone: true)
        let fps = try await SlowMoComposer.videoFrameRate(of: clip)
        XCTAssertEqual(fps, 24, accuracy: 0.5)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [])
    }
}
