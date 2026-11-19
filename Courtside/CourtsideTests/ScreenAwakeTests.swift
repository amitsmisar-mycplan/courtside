import XCTest
@testable import Courtside

/// Auto-lock is off only while something holds the screen awake (fix/recording-flow).
@MainActor
final class ScreenAwakeTests: XCTestCase {
    private var applied: [Bool] = []

    private func makeAwake() -> ScreenAwake {
        ScreenAwake { [unowned self] in applied.append($0) }
    }

    func testHoldingTurnsAutoLockOffAndReleasingTurnsItBackOn() {
        let awake = makeAwake()
        awake.hold(.recording)
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(applied, [true])
        awake.release(.recording)
        XCTAssertFalse(awake.isHeld)
        XCTAssertEqual(applied, [true, false])
    }

    func testOneScreenLettingGoDoesNotReEnableAutoLockUnderAnother() {
        let awake = makeAwake()
        awake.hold(.recording)
        awake.hold(.processing)
        awake.release(.processing)
        XCTAssertTrue(awake.isHeld, "still recording")
        XCTAssertEqual(applied, [true])
        awake.release(.recording)
        XCTAssertEqual(applied, [true, false])
    }

    func testRepeatedCallsChangeNothing() {
        let awake = makeAwake()
        awake.release(.recording)
        XCTAssertEqual(applied, [], "releasing what isn't held does nothing")
        awake.set(.recording, awake: true)
        awake.set(.recording, awake: true)
        XCTAssertEqual(applied, [true])
        awake.set(.recording, awake: false)
        awake.set(.recording, awake: false)
        XCTAssertEqual(applied, [true, false])
    }
}
