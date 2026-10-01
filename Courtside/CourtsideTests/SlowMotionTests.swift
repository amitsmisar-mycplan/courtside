import XCTest
@testable import Courtside

final class SlowMotionTests: XCTestCase {
    // MARK: Frame rate → speeds

    func testSixtyFpsOffersBothSpeeds() {
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 60), [.half, .quarter])
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 59.94), [.half, .quarter])
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 120), [.half, .quarter])
        XCTAssertNil(SlowMotion.limitationMessage(frameRate: 60))
    }

    func testThirtyFpsOffersHalfOnly() {
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 30), [.half])
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 29.97), [.half])
        XCTAssertEqual(SlowMotion.limitationMessage(frameRate: 29.97), "This video was recorded at 30 fps, so 0.25× isn't available.")
    }

    func testUnderThirtyFpsOffersNothing() {
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 24), [])
        XCTAssertEqual(SlowMotion.availableSpeeds(frameRate: 25), [])
        XCTAssertEqual(
            SlowMotion.limitationMessage(frameRate: 23.98),
            "This video was recorded at 24 fps, which doesn't have enough frames for slow motion."
        )
    }

    // MARK: Default segment

    func testDefaultSegmentInStandardClip() {
        // Mark sits 10 s into a 13 s clip.
        XCTAssertEqual(SlowMotion.defaultSegment(markInClip: 10, clipDuration: 13), SlowMoSegment(start: 8, end: 11.5))
    }

    func testDefaultSegmentClampsAtClipStart() {
        XCTAssertEqual(SlowMotion.defaultSegment(markInClip: 0.5, clipDuration: 13), SlowMoSegment(start: 0, end: 2))
    }

    func testDefaultSegmentClampsAtClipEnd() {
        XCTAssertEqual(SlowMotion.defaultSegment(markInClip: 12.5, clipDuration: 13), SlowMoSegment(start: 10.5, end: 13))
    }

    func testClipShorterThanSegmentIsSlowedEntirely() {
        XCTAssertEqual(SlowMotion.defaultSegment(markInClip: 1, clipDuration: 3), SlowMoSegment(start: 0, end: 3))
    }

    // MARK: Dragged segment

    func testDraggedSegmentClampsToClip() {
        XCTAssertEqual(SlowMotion.clamped(start: -4, end: 20, clipDuration: 13), SlowMoSegment(start: 0, end: 13))
    }

    func testDraggedSegmentKeepsMinimumLength() {
        XCTAssertEqual(SlowMotion.clamped(start: 5, end: 5.1, clipDuration: 13), SlowMoSegment(start: 5, end: 5.5))
        XCTAssertEqual(SlowMotion.clamped(start: 12.9, end: 13, clipDuration: 13), SlowMoSegment(start: 12.5, end: 13))
    }

    func testDraggedSegmentHandlesReversedHandles() {
        XCTAssertEqual(SlowMotion.clamped(start: 9, end: 6, clipDuration: 13), SlowMoSegment(start: 6, end: 9))
    }

    // MARK: Output duration

    func testOutputDurationForEachSpeed() {
        let segment = SlowMoSegment(start: 8, end: 11.5)
        XCTAssertEqual(SlowMotion.outputDuration(clipDuration: 13, segment: segment, speed: .half), 16.5, accuracy: 0.0001)
        XCTAssertEqual(SlowMotion.outputDuration(clipDuration: 13, segment: segment, speed: .quarter), 23.5, accuracy: 0.0001)
    }

    func testSizeEstimateScalesWithDuration() {
        XCTAssertEqual(SlowMotion.estimatedFileSize(clipFileSize: 13_000_000, clipDuration: 13, outputDuration: 23.5), 23_500_000)
        XCTAssertEqual(SlowMotion.estimatedFileSize(clipFileSize: 1, clipDuration: 0, outputDuration: 5), 0)
    }

    // MARK: Filenames

    func testSlowMoFilename() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(StorageManager.makeSlowMoFilename(clipID: id, speed: .quarter), "11111111-2222-3333-4444-555555555555-slowmo-0.25.mov")
        XCTAssertEqual(StorageManager.makeSlowMoFilename(clipID: id, speed: .half), "11111111-2222-3333-4444-555555555555-slowmo-0.5.mov")
    }
}
