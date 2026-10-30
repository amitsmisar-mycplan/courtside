import XCTest
@testable import Courtside

final class ClipWindowTests: XCTestCase {
    private let game: Double = 5400 // 90 minutes

    private func window(_ mark: Double, pre: Double = 10, post: Double = 3, duration: Double) -> ClipWindow {
        ClipWindow.around(mark: mark, preRoll: pre, postRoll: post, gameDuration: duration)
    }

    func testDefaultWindowIsThirteenSeconds() {
        let w = window(600, duration: game)
        XCTAssertEqual(w, ClipWindow(start: 590, end: 603))
        XCTAssertEqual(w.duration, 13)
    }

    func testMarkNearStartClampsToZero() {
        XCTAssertEqual(window(2, duration: game), ClipWindow(start: 0, end: 5))
    }

    func testMarkOneSecondBeforeEndClampsToDuration() {
        XCTAssertEqual(window(game - 1, duration: game), ClipWindow(start: game - 11, end: game))
    }

    func testMarkAtExactlyZero() {
        let w = window(0, duration: game)
        XCTAssertEqual(w, ClipWindow(start: 0, end: 3))
        XCTAssertTrue(w.isExtractable)
    }

    func testMarkAtExactlyDuration() {
        XCTAssertEqual(window(game, duration: game), ClipWindow(start: game - 10, end: game))
    }

    func testZeroLengthGame() {
        let w = window(0, duration: 0)
        XCTAssertEqual(w, ClipWindow(start: 0, end: 0))
        XCTAssertFalse(w.isExtractable)
    }

    func testMarkAtZeroWithNoPostRollIsNotExtractable() {
        XCTAssertFalse(window(0, post: 0, duration: game).isExtractable)
    }

    func testMarkBeyondDurationClampsToDuration() {
        XCTAssertEqual(window(game + 30, duration: game), ClipWindow(start: game - 10, end: game))
    }

    func testNonFiniteInputsDoNotProduceNonFiniteWindows() {
        let w = window(.nan, duration: .infinity)
        XCTAssertEqual(w, ClipWindow(start: 0, end: 0))
    }

    func testGameShorterThanWindow() {
        XCTAssertEqual(window(4, duration: 6), ClipWindow(start: 0, end: 6))
    }

    func testCustomRolls() {
        XCTAssertEqual(window(100, pre: 20, post: 10, duration: game), ClipWindow(start: 80, end: 110))
        XCTAssertEqual(window(100, pre: 5, post: 0, duration: game), ClipWindow(start: 95, end: 100))
    }

    // MARK: Trim

    func testTrimBoundsAreThirtyBeforeAndFifteenAfterTheTap() {
        let current = ClipWindow(start: 590, end: 603)
        XCTAssertEqual(ClipWindow.trimBounds(mark: 600, gameDuration: game, current: current), ClipWindow(start: 570, end: 615))
    }

    func testTrimBoundsClampToTheSourceVideo() {
        // Tap 5 s in: can't reach 30 s before. Tap 5 s from the end: can't reach 15 s after.
        XCTAssertEqual(ClipWindow.trimBounds(mark: 5, gameDuration: game, current: ClipWindow(start: 0, end: 8)),
                       ClipWindow(start: 0, end: 20))
        XCTAssertEqual(ClipWindow.trimBounds(mark: game - 5, gameDuration: game, current: ClipWindow(start: game - 15, end: game)),
                       ClipWindow(start: game - 35, end: game))
    }

    func testTrimBoundsNeverShrinkAnOlderWiderClip() {
        let wide = ClipWindow(start: 550, end: 620)
        XCTAssertEqual(ClipWindow.trimBounds(mark: 600, gameDuration: game, current: wide), wide)
    }

    func testDraggingAnEdgeClampsToTheBounds() {
        let bounds = ClipWindow(start: 570, end: 615)
        let window = ClipWindow(start: 590, end: 603)
        XCTAssertEqual(window.trimming(.start, to: 500, within: bounds), ClipWindow(start: 570, end: 603))
        XCTAssertEqual(window.trimming(.end, to: 700, within: bounds), ClipWindow(start: 590, end: 615))
        XCTAssertEqual(window.trimming(.start, to: 595, within: bounds), ClipWindow(start: 595, end: 603))
    }

    func testTrimKeepsAtLeastTwoSeconds() {
        let bounds = ClipWindow(start: 570, end: 615)
        let window = ClipWindow(start: 590, end: 603)
        XCTAssertEqual(window.trimming(.start, to: 602, within: bounds), ClipWindow(start: 601, end: 603))
        XCTAssertEqual(window.trimming(.end, to: 589, within: bounds), ClipWindow(start: 590, end: 592))
        // Pinned against the edge of the bounds, the minimum still holds.
        XCTAssertEqual(ClipWindow(start: 570, end: 572).trimming(.end, to: 560, within: bounds), ClipWindow(start: 570, end: 572))
    }

    func testTrimInsideTinyBoundsKeepsEverything() {
        let bounds = ClipWindow(start: 0, end: 1.5)
        XCTAssertEqual(ClipWindow(start: 0, end: 1.5).trimming(.start, to: 1, within: bounds), bounds)
    }

    func testDefaultTrimIsTenBeforeThreeAfterClamped() {
        XCTAssertEqual(ClipWindow.defaultTrim(mark: 600, gameDuration: game), ClipWindow(start: 590, end: 603))
        XCTAssertEqual(ClipWindow.defaultTrim(mark: 4, gameDuration: game), ClipWindow(start: 0, end: 7))
        XCTAssertEqual(ClipWindow.defaultTrim(mark: game - 1, gameDuration: game), ClipWindow(start: game - 11, end: game))
    }

    // MARK: Settings

    func testSettingsClampStoredValues() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: ClipSettings.preRollKey)
            defaults.removeObject(forKey: ClipSettings.postRollKey)
        }
        defaults.removeObject(forKey: ClipSettings.preRollKey)
        defaults.removeObject(forKey: ClipSettings.postRollKey)
        XCTAssertEqual(ClipSettings.preRoll, 10)
        XCTAssertEqual(ClipSettings.postRoll, 3)

        defaults.set(99.0, forKey: ClipSettings.preRollKey)
        defaults.set(-4.0, forKey: ClipSettings.postRollKey)
        XCTAssertEqual(ClipSettings.preRoll, 20)
        XCTAssertEqual(ClipSettings.postRoll, 0)
    }
}
