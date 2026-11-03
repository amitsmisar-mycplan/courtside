import Foundation

/// A span of the source game video, in seconds.
struct ClipWindow: Equatable {
    static let defaultPreRoll: Double = 10
    static let defaultPostRoll: Double = 3
    static let preRollRange: ClosedRange<Double> = 5...20
    static let postRollRange: ClosedRange<Double> = 0...10
    /// Shorter windows aren't worth exporting.
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
}

/// Trimming an existing clip (decision 0015): how far the edges may go, relative to the tap.
extension ClipWindow {
    /// Furthest the start may reach before the tap, and the end after it.
    static let trimMaxBeforeMark: Double = 30
    static let trimMaxAfterMark: Double = 15
    /// Shortest clip a trim may leave.
    static let trimMinimumDuration: Double = 2

    enum Edge { case start, end }

    /// The range a trim may cover: `[mark - 30, mark + 15]`, clamped to the source video. Widened
    /// to include `current`, so a clip made under older rules is never forced shorter.
    static func trimBounds(mark: Double, gameDuration: Double, current: ClipWindow) -> ClipWindow {
        let duration = gameDuration.isFinite ? max(0, gameDuration) : 0
        let lower = min(max(0, mark - trimMaxBeforeMark), max(0, current.start))
        let upper = max(min(duration, mark + trimMaxAfterMark), min(duration, current.end))
        return ClipWindow(start: lower, end: upper)
    }

    /// Moves one edge to `seconds`, kept inside `bounds` and at least `trimMinimumDuration`
    /// from the other edge. If the bounds themselves are shorter than that, the whole bounds.
    func trimming(_ edge: Edge, to seconds: Double, within bounds: ClipWindow) -> ClipWindow {
        let minimum = Self.trimMinimumDuration
        guard bounds.duration > minimum else { return bounds }
        let value = seconds.isFinite ? seconds : (edge == .start ? start : end)
        switch edge {
        case .start:
            let end = min(max(self.end, bounds.start + minimum), bounds.end)
            return ClipWindow(start: min(max(value, bounds.start), end - minimum), end: end)
        case .end:
            let start = max(min(self.start, bounds.end - minimum), bounds.start)
            return ClipWindow(start: start, end: max(min(value, bounds.end), start + minimum))
        }
    }

    /// "Reset to default window": 10 s before the tap, 3 s after, clamped to the source video.
    static func defaultTrim(mark: Double, gameDuration: Double) -> ClipWindow {
        around(mark: mark, preRoll: defaultPreRoll, postRoll: defaultPostRoll, gameDuration: gameDuration)
    }
}

/// User-adjustable pre/post roll, stored in UserDefaults and clamped to the allowed ranges.
/// How clips and trims are encoded (decision 0023). Clips are re-encoded to land on the tap, and at
/// 4K that's slow; "1080p (faster)" caps them at 1920 on the long side. Existing clips are never remade.
enum ClipQuality: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// At most 1920 on the long side, HEVC 1080p preset. A source that small or smaller keeps its size.
    case hd1080
    /// The source's own resolution, HEVC Highest Quality: the behavior before decision 0023.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd1080: "1080p (faster)"
        case .full: "Full quality"
        }
    }
}

enum ClipSettings {
    static let preRollKey = "clipPreRollSeconds"
    static let postRollKey = "clipPostRollSeconds"
    static let qualityKey = "clipQuality"

    /// Used for new clips and trims. Defaults to 1080p.
    static var quality: ClipQuality {
        UserDefaults.standard.string(forKey: qualityKey).flatMap(ClipQuality.init(rawValue:)) ?? .hd1080
    }

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
