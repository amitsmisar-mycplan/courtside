import CoreGraphics
import Foundation

/// Aim points on the exported file's own timeline (decision 0028): where the 9:16 window points,
/// at which second of the file. Pure geometry, like `VerticalFraming`; the export sheet's preview
/// and `ExportComposer` both move the window with `motion(...)`, so they can't disagree.
struct AimPath: Hashable, Sendable {
    struct Key: Hashable, Sendable {
        /// Seconds into the file.
        var time: Double
        /// Middle of the window, 0...1 from the top-left of the video.
        var center: CGPoint
    }

    /// Fastest the window may move, in window widths (or heights) per second at the middle of a
    /// glide. A move across a 1080p clip at 60 % zoom takes at least about 2 s, so it never whips.
    static let maxSpeed: Double = 1.0
    /// Peak speed of `ease` over its average speed: the cap allows this much less distance per glide.
    static let easePeak: Double = 1.5

    /// In time order.
    private(set) var keys: [Key]

    init(keys: [Key]) {
        self.keys = keys.sorted { $0.time < $1.time }
    }

    /// One aim for the whole file: exports exactly as a single framing does.
    var isStatic: Bool {
        guard let first = keys.first else { return true }
        return keys.allSatisfy { abs($0.center.x - first.center.x) < 0.0005 && abs($0.center.y - first.center.y) < 0.0005 }
    }

    /// For cache keys: two paths that look the same compare equal.
    var rounded: AimPath {
        func round(_ value: Double, _ step: Double) -> Double { (value / step).rounded() * step }
        return AimPath(keys: keys.map {
            Key(time: round($0.time, 0.01), center: CGPoint(x: round($0.center.x, 0.001), y: round($0.center.y, 0.001)))
        })
    }

    /// Slow at both ends, fastest in the middle (smoothstep). 0...1 in, 0...1 out.
    static func ease(_ progress: Double) -> Double {
        let u = min(max(progress, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// The window's movement at `zoom` for a video of `videoSize`: each point's aim held inside the
    /// video at that zoom, and each glide shortened when reaching the next point in time would mean
    /// moving faster than `maxSpeed`. The window then goes as far as it can and the next glide
    /// starts from there; it is never late, it falls short.
    func motion(zoom: Double, videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> AimMotion {
        let zoom = VerticalFraming(zoom: zoom).clamped(videoSize: videoSize, canvas: canvas).zoom
        let window = VerticalFraming.windowSize(zoom: zoom, videoSize: videoSize, canvas: canvas)
        let windowWidth = window.width / max(videoSize.width, 1)
        let windowHeight = window.height / max(videoSize.height, 1)
        var reached: [Key] = []
        for key in keys {
            let target = VerticalFraming(zoom: zoom, center: key.center).clamped(videoSize: videoSize, canvas: canvas).center
            guard let last = reached.last else {
                reached.append(Key(time: key.time, center: target))
                continue
            }
            let dx = target.x - last.center.x, dy = target.y - last.center.y
            // Distance in window sizes, so the cap is the same on screen at any zoom.
            let distance = max(abs(dx) / max(windowWidth, 0.0001), abs(dy) / max(windowHeight, 0.0001))
            let allowed = Self.maxSpeed * max(key.time - last.time, 0) / Self.easePeak
            let fraction = distance > allowed ? allowed / distance : 1
            reached.append(Key(time: key.time, center: CGPoint(x: last.center.x + dx * fraction, y: last.center.y + dy * fraction)))
        }
        return AimMotion(zoom: zoom, keys: reached)
    }
}

/// An `AimPath` ready to play: aims clamped and glides capped for one zoom and video size.
struct AimMotion: Sendable {
    let zoom: Double
    /// Where the window actually is at each point's time.
    let keys: [AimPath.Key]

    /// Held at the first aim before the first point and at the last after the last; in between,
    /// an eased glide from each point to the next.
    func center(at time: Double) -> CGPoint {
        guard let first = keys.first, let last = keys.last else { return CGPoint(x: 0.5, y: 0.5) }
        if time <= first.time { return first.center }
        if time >= last.time { return last.center }
        // The last key at or before `time`.
        var low = 0, high = keys.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if keys[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        let from = keys[low], to = keys[min(low + 1, keys.count - 1)]
        let span = to.time - from.time
        guard span > 0 else { return to.center }
        let e = AimPath.ease((time - from.time) / span)
        return CGPoint(x: from.center.x + (to.center.x - from.center.x) * e, y: from.center.y + (to.center.y - from.center.y) * e)
    }

    func framing(at time: Double) -> VerticalFraming {
        VerticalFraming(zoom: zoom, center: center(at: time))
    }
}
