import Foundation

enum SlowMoSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case quarter = 0.25

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half: "0.5×"
        case .quarter: "0.25×"
        }
    }

    /// Used in filenames, e.g. `-slowmo-0.25`.
    var fileComponent: String {
        switch self {
        case .half: "0.5"
        case .quarter: "0.25"
        }
    }

    /// Lowest source frame rate at which this speed still looks like slow motion rather than
    /// a stutter (~15 fps of real frames once stretched). Thresholds sit a little below 30/60
    /// because phone video reports rates like 29.97, 59.94, or slightly lower when variable.
    var minimumSourceFrameRate: Float {
        switch self {
        case .half: 28
        case .quarter: 55
        }
    }
}

/// The part of a clip that plays slowly, in seconds on the clip's own timeline.
struct SlowMoSegment: Equatable {
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

/// Pure slow-motion rules: which speeds a video supports, where the slow segment sits,
/// and how long the output is. No AVFoundation here.
enum SlowMotion {
    /// Default slow segment is `[mark - leadIn, mark + followThrough]`.
    static let leadIn: Double = 2.0
    static let followThrough: Double = 1.5
    /// Shortest slow segment the editor allows.
    static let minimumSegment: Double = 0.5

    static func availableSpeeds(frameRate: Float) -> [SlowMoSpeed] {
        SlowMoSpeed.allCases.filter { frameRate >= $0.minimumSourceFrameRate }
    }

    /// Plain explanation when the frame rate limits the options; nil when everything is available.
    static func limitationMessage(frameRate: Float) -> String? {
        let fps = Int(frameRate.rounded())
        switch availableSpeeds(frameRate: frameRate).count {
        case SlowMoSpeed.allCases.count:
            return nil
        case 0:
            return "This video was recorded at \(fps) fps, which doesn't have enough frames for slow motion."
        default:
            return "This video was recorded at \(fps) fps, so 0.25× isn't available."
        }
    }

    /// The default segment around the mark, clamped to the clip. A clip shorter than the
    /// default segment is slowed entirely.
    static func defaultSegment(markInClip: Double, clipDuration: Double) -> SlowMoSegment {
        let duration = max(0, clipDuration)
        if duration <= leadIn + followThrough {
            return SlowMoSegment(start: 0, end: duration)
        }
        return clamped(start: markInClip - leadIn, end: markInClip + followThrough, clipDuration: duration)
    }

    /// Keeps a user-dragged segment inside the clip and at least `minimumSegment` long.
    static func clamped(start: Double, end: Double, clipDuration: Double) -> SlowMoSegment {
        let duration = max(0, clipDuration)
        guard duration > minimumSegment else { return SlowMoSegment(start: 0, end: duration) }
        var lower = min(max(min(start, end), 0), duration)
        var upper = min(max(max(start, end), 0), duration)
        if upper - lower < minimumSegment {
            upper = min(duration, lower + minimumSegment)
            lower = max(0, upper - minimumSegment)
        }
        return SlowMoSegment(start: lower, end: upper)
    }

    /// Length of the rendered video: normal parts at 1×, the slow segment stretched.
    static func outputDuration(clipDuration: Double, segment: SlowMoSegment, speed: SlowMoSpeed) -> Double {
        clipDuration - segment.duration + segment.duration / speed.rawValue
    }

    /// Rough size of the render, scaled from the original clip's bitrate. An upper bound:
    /// stretched frames compress at least as well as the originals.
    static func estimatedFileSize(clipFileSize: Int64, clipDuration: Double, outputDuration: Double) -> Int64 {
        guard clipDuration > 0 else { return 0 }
        return Int64(Double(clipFileSize) * outputDuration / clipDuration)
    }
}
