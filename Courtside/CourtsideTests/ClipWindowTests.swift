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

    // MARK: Nudge

    func testNudgeStartEarlier() {
        let w = ClipWindow(start: 590, end: 603)
        XCTAssertEqual(w.nudged(startBy: -1, endBy: 0, gameDuration: game), ClipWindow(start: 589, end: 603))
    }

    func testNudgeClampsAtEdges() {
        XCTAssertEqual(
            ClipWindow(start: 0.5, end: 10).nudged(startBy: -1, endBy: 0, gameDuration: game),
            ClipWindow(start: 0, end: 10)
        )
        XCTAssertNil(ClipWindow(start: 0, end: 10).nudged(startBy: -1, endBy: 0, gameDuration: game))
        XCTAssertNil(ClipWindow(start: 10, end: game).nudged(startBy: 0, endBy: 1, gameDuration: game))
    }

    func testNudgeRefusesTooShort() {
        XCTAssertNil(ClipWindow(start: 10, end: 11).nudged(startBy: 1, endBy: 0, gameDuration: game))
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
