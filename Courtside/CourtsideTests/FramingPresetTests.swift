import AVFoundation
import XCTest
@testable import Courtside

/// Wide / Medium / Tight for Vertical (decision 0032): points on decision 0024's zoom scale, picked
/// by how much of the video's width the 9:16 frame keeps.
final class FramingPresetTests: XCTestCase {
    private static let uhd = CGSize(width: 3840, height: 2160)
    private static let hd = CGSize(width: 1920, height: 1080)
    private static let sd = CGSize(width: 1280, height: 720)
    private static let tiny = CGSize(width: 320, height: 180)

    private func share(_ preset: FramingPreset, _ size: CGSize) -> Double {
        FramingPreset.widthShare(zoom: preset.zoom(videoSize: size), videoSize: size)
    }

    func testPresetsKeepTheirShareOfTheWidthOnTheExistingScale() {
        for size in [Self.uhd, Self.hd] {
            XCTAssertEqual(share(.wide, size), 2.0 / 3, accuracy: 0.001, "Wide keeps two thirds")
            XCTAssertEqual(share(.medium, size), 0.5, accuracy: 0.001, "Medium keeps half")
            // The zoom is a point on 0024's own scale, so the window it gives is 0024's window.
            let zoom = FramingPreset.medium.zoom(videoSize: size)
            let window = VerticalFraming(zoom: zoom).window(videoSize: size)
            XCTAssertEqual(Double(window.width), 0.5, accuracy: 0.001)
        }
        // 16:9 lands on the same zooms at any resolution.
        XCTAssertEqual(FramingPreset.wide.zoom(videoSize: Self.hd), 0.2314, accuracy: 0.0005)
        XCTAssertEqual(FramingPreset.medium.zoom(videoSize: Self.hd), 0.4629, accuracy: 0.0005)
    }

    func testTightIsTheResolutionLimit() {
        XCTAssertEqual(FramingPreset.tight.zoom(videoSize: Self.uhd), 1, "4K fills the frame")
        XCTAssertEqual(share(.tight, Self.uhd), 0.316, accuracy: 0.001)
        XCTAssertEqual(FramingPreset.tight.zoom(videoSize: Self.hd), VerticalFraming.maxZoom(videoSize: Self.hd),
                       "1080p: Tight is the 1.5× cap, about 77 %")
        XCTAssertEqual(FramingPreset.tight.zoom(videoSize: Self.hd), 0.771, accuracy: 0.002)
        XCTAssertEqual(share(.tight, Self.hd), 0.375, accuracy: 0.002)
    }

    func testLowResolutionClipsOfferFewerChoices() {
        XCTAssertEqual(FramingPreset.distinct(videoSize: Self.uhd), [.wide, .medium, .tight])
        XCTAssertEqual(FramingPreset.distinct(videoSize: Self.hd), [.wide, .medium, .tight])
        // 720p can't zoom past about 36 %: Medium is held there and Tight would be the same.
        XCTAssertEqual(FramingPreset.medium.zoom(videoSize: Self.sd), VerticalFraming.maxZoom(videoSize: Self.sd), accuracy: 0.0001)
        XCTAssertEqual(FramingPreset.distinct(videoSize: Self.sd), [.wide, .medium])
        XCTAssertEqual(FramingPreset.starting(videoSize: Self.sd), .medium)
        // Too small to zoom at all: one choice, the whole width.
        XCTAssertEqual(FramingPreset.distinct(videoSize: Self.tiny), [.wide])
        XCTAssertEqual(FramingPreset.wide.zoom(videoSize: Self.tiny), 0)
        XCTAssertEqual(FramingPreset.starting(videoSize: Self.tiny), .wide)
        XCTAssertEqual(FramingPreset.starting(videoSize: Self.hd), .medium)
    }

    func testWiderThan16By9StillLandsOnItsShares() {
        let ultraWide = CGSize(width: 2560, height: 1080)
        XCTAssertEqual(share(.wide, ultraWide), 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(share(.medium, ultraWide), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FramingPreset.wide.zoom(videoSize: ultraWide), FramingPreset.medium.zoom(videoSize: ultraWide))
    }

    // MARK: The sheet's session

    @MainActor
    func testSessionStartsAtMediumReadsOutTheShareAndWarnsAboutTheSides() async throws {
        let url = try await makeClip(size: Self.hd)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ClipExportSession(clipID: UUID(), source: url, photos: NoPhotos())
        await session.load()

        XCTAssertEqual(session.framingPresets, [.wide, .medium, .tight])
        XCTAssertEqual(session.selectedPreset, .medium)
        XCTAssertEqual(session.widthSharePercent, 50)
        XCTAssertTrue(session.mayCutOffSides, "one aim point for the whole clip")

        session.selectPreset(.wide)
        XCTAssertEqual(session.widthSharePercent, 65, "two thirds, to the nearest 5")
        session.selectPreset(.tight)
        XCTAssertEqual(session.widthSharePercent, 40, "37.5 %, to the nearest 5")
        XCTAssertTrue(session.isZoomLimited, "1080p Tight sits on the quality limit")
        XCTAssertTrue(session.mayCutOffSides)

        // Advanced: any zoom; no preset is selected then. The old 60 % default keeps about 45 %.
        session.setZoom(0.6)
        XCTAssertNil(session.selectedPreset)
        XCTAssertEqual(session.widthSharePercent, 45)
        session.setZoom(0)
        XCTAssertEqual(session.widthSharePercent, 100)
        XCTAssertFalse(session.mayCutOffSides, "the whole width: nothing to cut off")

        // With a second aim point the warning shows only for Tight.
        session.selectPreset(.medium)
        session.preview.seek(to: session.preview.duration * 0.8)
        session.addPoint()
        XCTAssertEqual(session.aimKeys.count, 2)
        XCTAssertFalse(session.mayCutOffSides)
        session.selectPreset(.tight)
        XCTAssertTrue(session.mayCutOffSides)
    }

    @MainActor
    func testOneStaticZoomPerExport() async throws {
        let url = try await makeClip(size: Self.hd)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ClipExportSession(clipID: UUID(), source: url, photos: NoPhotos())
        await session.load()
        session.selectPreset(.wide)
        // The export's framing carries the preset's zoom, unchanged (decision 0028: one zoom per export).
        XCTAssertEqual(session.framing.zoom, FramingPreset.wide.zoom(videoSize: Self.hd), accuracy: 0.0001)
        session.preview.seek(to: session.preview.duration * 0.9)
        XCTAssertEqual(session.framing.zoom, FramingPreset.wide.zoom(videoSize: Self.hd), accuracy: 0.0001)
    }

    // MARK: Fixtures

    private struct NoPhotos: PhotoLibrarySaving {
        func requestAddAccess() async -> PhotoAccess { .granted }
        func saveVideo(at url: URL) async throws {}
    }

    /// A one-second plain clip of `size` in the temporary folder.
    private func makeClip(size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("framing-\(UUID().uuidString).mov")
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
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
