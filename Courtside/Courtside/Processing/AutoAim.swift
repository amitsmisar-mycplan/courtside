import CoreGraphics
import Foundation

/// Turns where the motion was (`MotionAnalyzer`) into aim points (decision 0033), under the same
/// rules as hand-set points (decision 0028): at most `AimTrack.manualLimit`, eased glides, and the
/// 1-window-width-per-second cap, all applied by `AimPath.motion`. Pure, like `AimPath`.
enum AutoAim {
    /// Samples in the median that drops brief outliers (a ref crossing, a sub walking on): about 1.25 s.
    static let medianSpan = 5
    /// Points closer together than this aren't added: the window would barely move between them.
    static let minimumSpacing = 1.0
    /// The action counts as in frame while it's within this share of the window's width of its
    /// middle; only straying further than that costs.
    static let slack = 0.25
    /// A point is added only when it cuts the average miss by at least this share of the width.
    static let minimumGain = 0.003

    /// Aim points on the analysed file's timeline for a Vertical export at `zoom`. One centered
    /// point when there's no motion to follow, or the frame already shows the whole width.
    static func keys(from samples: [MotionSample], zoom: Double, videoSize: CGSize,
                     canvas: CGSize = ExportFormat.verticalRenderSize) -> [AimPath.Key] {
        let centered = [AimPath.Key(time: 0, center: CGPoint(x: 0.5, y: 0.5))]
        let window = VerticalFraming.windowSize(zoom: zoom, videoSize: videoSize, canvas: canvas)
        let windowShare = Double(window.width / max(videoSize.width, 1))
        guard windowShare < 0.99 else { return centered }
        let times = samples.map(\.time)
        guard let target = smoothedPath(samples) else { return centered }

        func miss(_ keys: [AimPath.Key]) -> Double {
            let motion = AimPath(keys: keys).motion(zoom: zoom, videoSize: videoSize, canvas: canvas)
            var total = 0.0
            for (time, x) in zip(times, target) {
                total += max(0, abs(Double(motion.center(at: time).x) - x) - windowShare * slack)
            }
            return total / Double(target.count)
        }

        // One aim for the whole clip first, at the middle of the action, then the points that help most.
        let sorted = target.sorted()
        var keys = [AimPath.Key(time: 0, center: CGPoint(x: sorted[sorted.count / 2], y: 0.5))]
        var current = miss(keys)
        while keys.count < AimTrack.manualLimit {
            var best: (keys: [AimPath.Key], miss: Double)?
            for (time, x) in zip(times, target)
            where !keys.contains(where: { abs($0.time - time) < minimumSpacing }) {
                let trial = AimPath(keys: keys + [AimPath.Key(time: time, center: CGPoint(x: x, y: 0.5))]).keys
                let value = miss(trial)
                if value < (best?.miss ?? .infinity) { best = (trial, value) }
            }
            guard let best, current - best.miss >= minimumGain else { break }
            keys = best.keys
            current = best.miss
        }

        // Nudge each point's aim where that helps (a glide often wants to start a little early).
        for _ in 0..<2 {
            for index in keys.indices {
                for step in [-0.08, -0.04, 0.04, 0.08] {
                    var trial = keys
                    trial[index].center.x = min(max(trial[index].center.x + step, 0), 1)
                    let value = miss(trial)
                    if value < current - 0.0001 {
                        keys = trial
                        current = value
                    }
                }
            }
        }

        // Store where the window really goes (aims held inside the video, glides within the cap),
        // so the editor shows the points as they play.
        return AimPath(keys: keys).motion(zoom: zoom, videoSize: videoSize, canvas: canvas).keys
            .map { AimPath.Key(time: $0.time, center: CGPoint(x: $0.center.x, y: 0.5)) }
    }

    /// The motion's middle at each sample: gaps filled from their neighbors, then brief outliers
    /// dropped (median) and the rest smoothed. Nil when too little of the clip had motion to follow.
    static func smoothedPath(_ samples: [MotionSample]) -> [Double]? {
        let known = samples.indices.filter { samples[$0].x != nil }
        guard known.count >= 3, Double(known.count) >= Double(samples.count) * 0.25 else { return nil }
        var filled = samples.map(\.x)
        for index in filled.indices where filled[index] == nil {
            let before = known.last { $0 < index }
            let after = known.first { $0 > index }
            switch (before, after) {
            case let (before?, after?):
                let a = samples[before].x!, b = samples[after].x!
                let t = (samples[index].time - samples[before].time) / max(samples[after].time - samples[before].time, 0.001)
                filled[index] = a + (b - a) * t
            case let (before?, nil): filled[index] = samples[before].x
            case let (nil, after?): filled[index] = samples[after].x
            case (nil, nil): break
            }
        }
        let values = filled.map { $0 ?? 0.5 }
        let half = medianSpan / 2
        let median = values.indices.map { index -> Double in
            let window = values[max(0, index - half)...min(values.count - 1, index + half)].sorted()
            return window[window.count / 2]
        }
        return median.indices.map { index in
            let window = median[max(0, index - 1)...min(median.count - 1, index + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
    }
}
