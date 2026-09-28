import Foundation

/// A span of the source game video, in seconds.
struct ClipWindow: Equatable {
    static let defaultPreRoll: Double = 10
    static let defaultPostRoll: Double = 3
    static let preRollRange: ClosedRange<Double> = 5...20
    static let postRollRange: ClosedRange<Double> = 0...10
    /// Shorter windows aren't worth exporting (and nudging below this is refused).
    static let minimumDuration: Double = 1

    let start: Double
    let end: Double

    var duration: Double { end - start }
    var isExtractable: Bool { duration >= Self.minimumDuration }

    /// `[mark - preRoll, mark + postRoll]`, clamped to `[0, gameDuration]`.
    static func around(
        mark: Double,
        preRoll: Double,
        postRoll: Double,
        gameDuration: Double
    ) -> ClipWindow {
        let duration = gameDuration.isFinite ? max(0, gameDuration) : 0
        let mark = mark.isFinite ? min(max(mark, 0), duration) : 0
        let start = max(0, mark - max(0, preRoll))
        let end = min(duration, mark + max(0, postRoll))
        return ClipWindow(start: start, end: end)
    }

    /// Shift either edge, clamped to the game. Nil when the result is unchanged or too short.
    func nudged(startBy startDelta: Double, endBy endDelta: Double, gameDuration: Double) -> ClipWindow? {
        let duration = max(0, gameDuration)
        let newStart = min(max(start + startDelta, 0), duration)
        let newEnd = min(max(end + endDelta, 0), duration)
        let result = ClipWindow(start: newStart, end: newEnd)
        guard result != self, result.isExtractable else { return nil }
        return result
    }
}

/// User-adjustable pre/post roll, stored in UserDefaults and clamped to the allowed ranges.
enum ClipSettings {
    static let preRollKey = "clipPreRollSeconds"
    static let postRollKey = "clipPostRollSeconds"

    static var preRoll: Double {
        value(for: preRollKey, default: ClipWindow.defaultPreRoll, range: ClipWindow.preRollRange)
    }

    static var postRoll: Double {
        value(for: postRollKey, default: ClipWindow.defaultPostRoll, range: ClipWindow.postRollRange)
    }

    private static func value(for key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        let stored = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}
