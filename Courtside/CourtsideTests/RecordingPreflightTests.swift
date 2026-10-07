import XCTest
@testable import Courtside

final class RecordingPreflightTests: XCTestCase {
    private func check(
        free: Int64 = 50_000_000_000, battery: Float = 0.9, charging: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false
    ) -> [RecordingPreflight.Issue] {
        RecordingPreflight.check(freeBytes: free, batteryLevel: battery, isCharging: charging, thermalState: thermal, isLowPowerMode: lowPower)
    }

    func testAllGoodHasNoIssues() {
        XCTAssertEqual(check(), [])
    }

    func testUnderEightGigabytesBlocks() {
        let issues = check(free: 7_000_000_000)
        XCTAssertEqual(issues.map(\.id), ["disk"])
        XCTAssertTrue(issues[0].blocksRecording)
    }

    func testLowBatteryWarnsOnlyWhenNotCharging() {
        XCTAssertEqual(check(battery: 0.3).map(\.id), ["battery"])
        XCTAssertFalse(check(battery: 0.3)[0].blocksRecording)
        XCTAssertEqual(check(battery: 0.3, charging: true), [])
        XCTAssertEqual(check(battery: 0.5), [], "exactly 50% is fine")
    }

    func testUnknownBatteryIsIgnored() {
        XCTAssertEqual(check(battery: -1), [])
    }

    func testHotPhoneAndLowPowerWarn() {
        XCTAssertEqual(check(thermal: .serious).map(\.id), ["thermal"])
        XCTAssertEqual(check(thermal: .critical).map(\.id), ["thermal"])
        XCTAssertEqual(check(thermal: .fair), [])
        XCTAssertEqual(check(lowPower: true).map(\.id), ["lowPower"])
    }

    func testThermalWarningsWhileRecording() {
        XCTAssertNil(RecordingPreflight.thermalWarning(for: .nominal))
        XCTAssertNil(RecordingPreflight.thermalWarning(for: .fair))
        XCTAssertEqual(RecordingPreflight.thermalWarning(for: .serious), "Phone is hot")
        XCTAssertEqual(RecordingPreflight.thermalWarning(for: .critical), "Phone is very hot — recording may stop")
    }
}
