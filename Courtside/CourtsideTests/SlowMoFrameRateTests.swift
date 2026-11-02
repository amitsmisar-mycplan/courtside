import AVFoundation
import XCTest
@testable import Courtside

/// Frame rate is measured from the typical gap between frames, so the ~0.2 s pause after the first
/// frame of a phone recording doesn't switch off slow motion (decision 0018).
final class SlowMoFrameRateTests: XCTestCase {
    /// Frame times of a clip cut from 0:00 of a phone recording: frame 0, a start-up pause, then
    /// frames at `fps`, sized so the old average (frames ÷ duration) reads `averageReads`.
    private func phoneClip(duration: Double, fps: Double, averageReads: Double) -> [Double] {
        let frames = Int((averageReads * duration).rounded())
        let pause = duration - Double(frames - 1) / fps
        XCTAssertGreaterThan(pause, 1 / fps, "the fixture must contain a start-up pause")
        return [0] + (1..<frames).map { pause + Double($0 - 1) / fps }
    }

    private func steady(seconds: Double, fps: Double, startingAt start: Double = 0) -> [Double] {
        (0..<Int(seconds * fps)).map { start + Double($0) / fps }
    }

    private func oldAverage(_ times: [Double], duration: Double) -> Double {
        Double(times.count) / duration
    }

    // MARK: Nov 1 corpus (docs/testing/corpus-nov-1.md)

    /// First clip of each Nov 1 video (tap at 7 s, window 0:00–0:10): the old reading, then the source rate.
    private let nov1FirstClips: [(file: String, oldReading: Double, sourceFPS: Double)] = [
        ("20261031_132814", 29.60, 29.98),
        ("20261031_144105", 29.43, 29.98),
        ("20261031_144828", 29.60, 29.99),
        ("20261031_150358", 29.40, 29.99),
        ("20261031_151837", 28.85, 29.95),
    ]

    func testNov1FirstClipsReadAsThirtyFps() throws {
        for clip in nov1FirstClips {
            let times = phoneClip(duration: 10, fps: clip.sourceFPS, averageReads: clip.oldReading)
            XCTAssertEqual(oldAverage(times, duration: 10), clip.oldReading, accuracy: 0.06, clip.file)
            let fps = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: times), clip.file)
            XCTAssertEqual(Double(fps), clip.sourceFPS, accuracy: 0.05, clip.file)
            XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [.half], clip.file)
        }
    }

    /// The trial run's first clip: tap at 1.0 s on 20261031_151837, window 0:00–0:04, read 27.25 fps,
    /// so slow mo was refused on real 30 fps footage.
    func testTrialRunShortFirstClipNowOffersHalfSpeed() throws {
        let times = phoneClip(duration: 4, fps: 29.95, averageReads: 27.25)
        XCTAssertEqual(oldAverage(times, duration: 4), 27.25, accuracy: 0.01)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: Float(oldAverage(times, duration: 4))), [], "the old reading")
        let fps = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: times))
        XCTAssertEqual(fps, 29.95, accuracy: 0.05)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [.half])
        XCTAssertEqual(SlowMotion.limitationMessage(frameRate: fps), "This video was recorded at 30 fps, so 0.25× isn't available.")
    }

    /// Open question 4: a 1.5 s clip of 30 fps footage used to read 26 fps.
    func testVeryShortThirtyFpsClip() throws {
        let fps = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: steady(seconds: 1.5, fps: 30)))
        XCTAssertEqual(fps, 30, accuracy: 0.01)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [.half])
    }

    // MARK: Still refused

    func testThirtyFpsNeverOffersQuarterSpeed() throws {
        for times in [steady(seconds: 13, fps: 29.97), phoneClip(duration: 10, fps: 30, averageReads: 28.9)] {
            let fps = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: times))
            XCTAssertFalse(SlowMotion.availableSpeeds(frameRate: fps).contains(.quarter))
        }
    }

    func testGenuinelyLowFrameRatesBehaveAsBefore() throws {
        for (rate, expected) in [(23.976, [SlowMoSpeed]()), (24, []), (25, []), (20, [])] {
            let plain = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: steady(seconds: 13, fps: rate)))
            XCTAssertEqual(Double(plain), rate, accuracy: 0.01)
            XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: plain), expected, "\(rate) fps")
            // A start-up pause must not push low-rate footage over the cutoff either.
            let paused = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: phoneClip(duration: 10, fps: rate, averageReads: rate - 0.6)))
            XCTAssertEqual(Double(paused), rate, accuracy: 0.01)
            XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: paused), expected, "\(rate) fps with a pause")
        }
    }

    func testSixtyFpsWithStartupPauseOffersBothSpeeds() throws {
        let fps = try XCTUnwrap(SlowMotion.frameRate(presentationTimes: phoneClip(duration: 4, fps: 59.94, averageReads: 55)))
        XCTAssertEqual(fps, 59.94, accuracy: 0.05)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [.half, .quarter])
    }

    func testOrderDoesNotMatterAndTooFewFramesGiveNil() {
        let times = steady(seconds: 2, fps: 30)
        XCTAssertEqual(SlowMotion.frameRate(presentationTimes: times.reversed()), SlowMotion.frameRate(presentationTimes: times))
        XCTAssertNil(SlowMotion.frameRate(presentationTimes: []))
        XCTAssertNil(SlowMotion.frameRate(presentationTimes: [0, 0.033]))
    }

    // MARK: Real files

    /// A 30 fps source with a 0.4 s pause after frame 1, clipped from 0:00 through the real export path.
    func testRealClipWithStartupPauseReadsThirtyFps() async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "source.mov")
        try await TestMedia.makeVideo(at: source, seconds: 4, fps: 30, firstFrameGap: 0.4, withTone: false)
        let clip = work.appending(path: "clip.mov")
        try await ClipExtractor.export(source: source, window: ClipWindow(start: 0, end: 3), to: clip) { _ in }

        let tracks = try await AVURLAsset(url: clip).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let nominal = try await track.load(.nominalFrameRate)
        XCTAssertLessThan(nominal, 28, "the fixture reproduces the old under-reading")

        let fps = try await SlowMoComposer.videoFrameRate(of: clip)
        XCTAssertEqual(fps, 30, accuracy: 0.1)
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: fps), [.half])
    }
}
