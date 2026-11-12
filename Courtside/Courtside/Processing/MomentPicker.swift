import Foundation

/// What "Find Moments" heard in one video, one value per second (decision 0029). Numbers only:
/// no audio is kept. Saved while listening so a scan cut short picks up where it stopped.
struct MomentSignal: Codable, Equatable, Sendable {
    /// Format of the saved file; a different one is ignored and the video is listened to again.
    static let currentVersion = 1

    var version = Self.currentVersion
    /// Loudness of each second, in dB below full scale.
    var loudness: [Float] = []
    /// The built-in sound classifier's confidence, 0...1, highest over the windows covering each second.
    var cheering: [Float] = []
    /// Applause and clapping.
    var applause: [Float] = []
    /// Yell, shout, screaming and children shouting.
    var shouting: [Float] = []
    /// The classifier's general "crowd".
    var crowd: [Float] = []

    /// Seconds listened to so far.
    var count: Int { loudness.count }

    /// How much crowd reaction each second has: the four groups added up, at most 1.
    var reaction: [Double] {
        (0..<count).map { min(1, Double(cheering[$0] + applause[$0] + shouting[$0] + crowd[$0])) }
    }

    /// The loudest group at `second`, or `.loud` when the classifier heard almost nothing crowd-like.
    func sound(at second: Int) -> SuggestedMoment.Sound {
        guard second >= 0, second < count else { return .loud }
        let groups: [(SuggestedMoment.Sound, Float)] = [
            (.cheering, cheering[second]), (.applause, applause[second]),
            (.shouting, shouting[second]), (.crowd, crowd[second]),
        ]
        let top = groups.max { $0.1 < $1.1 }!
        return top.1 < MomentPicker.Settings.quietReaction ? .loud : top.0
    }

    /// Keeps the first `seconds` seconds, for resuming on a whole second.
    func prefix(_ seconds: Int) -> MomentSignal {
        let n = max(0, min(seconds, count))
        return MomentSignal(
            loudness: Array(loudness.prefix(n)), cheering: Array(cheering.prefix(n)),
            applause: Array(applause.prefix(n)), shouting: Array(shouting.prefix(n)), crowd: Array(crowd.prefix(n))
        )
    }
}

/// Turns a video's per-second sound into a short list of moments worth a look (decision 0029).
/// Pure: the same numbers always give the same list.
///
/// Each signal is measured against its own video. A rolling median over the surrounding
/// 90 seconds is the noise floor (a loud, echoey gym has a high one), and a second scores by how
/// far above that floor it is, in units of the video's own typical spread. Crowd reaction from the
/// classifier carries most of the weight; loudness carries the rest, so it decides between similar
/// cheers and still finds moments when the classifier hears nothing.
enum MomentPicker {
    struct Settings: Equatable, Sendable {
        /// Seconds either side of a second that make up its noise floor.
        var floorHalfWindow = 45
        var reactionWeight = 0.8
        var loudnessWeight = 0.2
        /// A second must stand this many spreads above the video's typical score...
        var spreads = 3.0
        /// ...and at least this high, so a flat video suggests nothing.
        var minimumScore = 1.5
        /// Suggestions are at least this far apart.
        var spacing: Double = 20
        /// No suggestion this close to an existing mark: the default clip window, 10 s + 3 s.
        var markClearance: Double = ClipWindow.defaultPreRoll + ClipWindow.defaultPostRoll
        /// At most this many per hour of video (one per started 3 minutes), the strongest first,
        /// so the list stays reviewable.
        var perHour: Double = 20
        /// Even a very short video can get this many.
        var minimumCount = 1

        /// Below this, the classifier heard nothing crowd-like at that second.
        static let quietReaction: Float = 0.02
        /// Spreads are never taken below these: a perfectly flat signal shouldn't make noise stand out.
        static let minimumReactionSpread = 0.01
        static let minimumLoudnessSpread = 0.5
        /// A second's lift above its floor counts at most this many spreads (only matters when a
        /// spread is near zero, as in digital silence).
        static let maximumLift = 100.0
    }

    struct Candidate: Equatable, Sendable {
        /// Seconds into the video: where the mark goes.
        var seconds: Double
        var score: Double
        var sound: SuggestedMoment.Sound
    }

    /// The moments in `signal`, in time order, skipping any near `marks` (seconds in the same video).
    static func pick(_ signal: MomentSignal, avoiding marks: [Double], settings: Settings = Settings()) -> [Candidate] {
        let peaks = pick(
            reaction: signal.reaction, loudness: signal.loudness.map(Double.init), avoiding: marks, settings: settings
        )
        return peaks.map { Candidate(seconds: $0.seconds, score: $0.score, sound: signal.sound(at: Int($0.seconds))) }
    }

    /// The core, on plain arrays (one value per second): `reaction` 0...1, `loudness` in dB.
    static func pick(
        reaction: [Double],
        loudness: [Double],
        avoiding marks: [Double],
        settings: Settings = Settings()
    ) -> [Candidate] {
        let n = min(reaction.count, loudness.count)
        guard n > 2 else { return [] }
        let reactionLift = lift(Array(reaction.prefix(n)), halfWindow: settings.floorHalfWindow,
                                minimumSpread: Settings.minimumReactionSpread)
        let loudnessLift = lift(Array(loudness.prefix(n)), halfWindow: settings.floorHalfWindow,
                                minimumSpread: Settings.minimumLoudnessSpread)
        let raw = (0..<n).map { settings.reactionWeight * reactionLift[$0] + settings.loudnessWeight * loudnessLift[$0] }
        // A cheer lasts a few seconds; a single loud second (a dropped ball, a door) shouldn't win.
        let score = (0..<n).map { i in
            let window = raw[max(0, i - 1)...min(n - 1, i + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
        let typical = median(score)
        let threshold = max(settings.minimumScore, typical + settings.spreads * max(spread(score), 0.25))

        // Local peaks above the threshold. A flat top counts once, at its first second.
        var peaks: [Int] = []
        for i in 0..<n where score[i] >= threshold {
            let left = i > 0 ? score[i - 1] : -.infinity
            let right = i < n - 1 ? score[i + 1] : -.infinity
            if score[i] > left && score[i] >= right { peaks.append(i) }
        }
        // Strongest first; between equal scores the louder one, then the earlier.
        peaks.sort { a, b in
            if score[a] != score[b] { return score[a] > score[b] }
            if loudnessLift[a] != loudnessLift[b] { return loudnessLift[a] > loudnessLift[b] }
            return a < b
        }

        let limit = max(settings.minimumCount, Int((Double(n) / 3600 * settings.perHour).rounded(.up)))
        var chosen: [Candidate] = []
        for i in peaks where chosen.count < limit {
            let seconds = Double(i)
            guard !marks.contains(where: { abs($0 - seconds) < settings.markClearance }),
                  !chosen.contains(where: { abs($0.seconds - seconds) < settings.spacing })
            else { continue }
            chosen.append(Candidate(seconds: seconds, score: score[i], sound: .loud))
        }
        return chosen.sorted { $0.seconds < $1.seconds }
    }

    /// How far each value stands above its rolling-median floor, in units of the signal's own
    /// spread (median absolute deviation from the floor), from 0 to `maximumLift`.
    static func lift(_ values: [Double], halfWindow: Int, minimumSpread: Double) -> [Double] {
        let floor = rollingMedian(values, halfWindow: halfWindow)
        let above = zip(values, floor).map { $0 - $1 }
        let scale = max(spread(above), minimumSpread)
        return above.map { min(Settings.maximumLift, max(0, $0 / scale)) }
    }

    static func rollingMedian(_ values: [Double], halfWindow: Int) -> [Double] {
        values.indices.map { i in
            median(Array(values[max(0, i - halfWindow)...min(values.count - 1, i + halfWindow)]))
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Median absolute deviation, scaled to match a standard deviation for normal noise.
    static func spread(_ values: [Double]) -> Double {
        let center = median(values)
        return 1.4826 * median(values.map { abs($0 - center) })
    }
}
