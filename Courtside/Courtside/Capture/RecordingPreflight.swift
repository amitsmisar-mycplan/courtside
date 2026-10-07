import Foundation
import UIKit

/// Checks before recording starts. Low disk blocks; the rest are warnings.
enum RecordingPreflight {
    struct Issue: Equatable, Identifiable {
        let id: String
        let message: String
        let blocksRecording: Bool
    }

    static let minimumFreeBytes: Int64 = 8 * 1_000_000_000
    static let lowBatteryLevel: Float = 0.5

    static func check(
        freeBytes: Int64,
        batteryLevel: Float,
        isCharging: Bool,
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool
    ) -> [Issue] {
        var issues: [Issue] = []
        if freeBytes < minimumFreeBytes {
            issues.append(Issue(
                id: "disk",
                message: "Only \(Format.bytes(freeBytes)) free. Recording a game needs at least \(Format.bytes(minimumFreeBytes)) — free up some space first.",
                blocksRecording: true
            ))
        }
        // batteryLevel is -1 when unknown (e.g. Simulator).
        if batteryLevel >= 0, batteryLevel < lowBatteryLevel, !isCharging {
            issues.append(Issue(
                id: "battery",
                message: "Battery is at \(Int((batteryLevel * 100).rounded()))% and not charging. A full game uses most of a charge — plug in if you can.",
                blocksRecording: false
            ))
        }
        if thermalState == .serious || thermalState == .critical {
            issues.append(Issue(
                id: "thermal",
                message: "The phone is already hot. Let it cool, or keep it out of direct sun, so recording isn't cut short.",
                blocksRecording: false
            ))
        }
        if isLowPowerMode {
            issues.append(Issue(
                id: "lowPower",
                message: "Low Power Mode is on, which can drop frames. Turn it off in Settings → Battery.",
                blocksRecording: false
            ))
        }
        return issues
    }

    /// The same checks with this device's current readings.
    @MainActor static func current() -> [Issue] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let charging = device.batteryState == .charging || device.batteryState == .full
        return check(
            freeBytes: StorageManager.availableCapacity(),
            batteryLevel: device.batteryLevel,
            isCharging: charging,
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Warning shown while recording, if any.
    static func thermalWarning(for state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .serious: "Phone is hot"
        case .critical: "Phone is very hot — recording may stop"
        default: nil
        }
    }
}
