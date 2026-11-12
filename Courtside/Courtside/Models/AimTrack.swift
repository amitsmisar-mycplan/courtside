import Foundation

/// Where the 9:16 window points at one moment of a clip, for Vertical exports (decision 0028).
struct AimPoint: Codable, Hashable, Sendable {
    /// Seconds in the clip's part video, like `Clip.markSeconds`, so a trim leaves the point on the
    /// same moment of the game.
    var time: Double
    /// Middle of the window, 0...1 from the left of the video.
    var x: Double
    /// Middle of the window, 0...1 from the top; nil is centered. Aiming up or down needs a zoom
    /// past 100 %, which the slider never reaches (decision 0024), so this is nil today.
    var y: Double?
}

/// A clip's Vertical aim over time, stored on `Clip` (decision 0028). No track on the clip means
/// one centered aim, as before. Points are in time order. The parent sets up to `manualLimit` by
/// hand; a tracker could later fill in many more with `origin: .automatic`, and playback and export
/// treat any number the same way.
struct AimTrack: Codable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        case manual
        case automatic
    }

    static let manualLimit = 5

    /// Format of the stored data, for a later change to it.
    var version = 1
    var origin: Origin
    private(set) var points: [AimPoint]

    init(points: [AimPoint], origin: Origin = .manual) {
        self.points = points.sorted { $0.time < $1.time }
        self.origin = origin
    }

    /// After a trim to `window`. Every point keeps its moment of the game. A point now outside the
    /// clip moves to the nearest edge; when several would land on the same edge, only the one
    /// closest to it is kept. So the clip still starts and ends aimed where it was at those moments
    /// before, and points come back unchanged if the trim is undone by trimming wider.
    /// Nil when there are no points.
    func fitted(to window: ClipWindow) -> AimTrack? {
        var result = points.filter { $0.time >= window.start && $0.time <= window.end }
        if let before = points.last(where: { $0.time < window.start }),
           !result.contains(where: { abs($0.time - window.start) < 0.001 }) {
            result.insert(AimPoint(time: window.start, x: before.x, y: before.y), at: 0)
        }
        if let after = points.first(where: { $0.time > window.end }),
           !result.contains(where: { abs($0.time - window.end) < 0.001 }) {
            result.append(AimPoint(time: window.end, x: after.x, y: after.y))
        }
        return result.isEmpty ? nil : AimTrack(points: result, origin: origin)
    }

    /// Stored on the clip as JSON; nil when unreadable, which falls back to a centered aim.
    static func decode(_ data: Data) -> AimTrack? {
        guard let track = try? JSONDecoder().decode(AimTrack.self, from: data), !track.points.isEmpty else { return nil }
        return AimTrack(points: track.points, origin: track.origin)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// Converts between game-video seconds, how aim points are stored, and seconds in the file being
/// exported: the clip, or its slow-motion version, where one segment plays stretched.
struct AimTimeline: Equatable, Sendable {
    /// The clip's start in its part's video.
    var clipStart: Double
    /// The slow segment on the clip's own timeline and its speed (0.5 plays twice as long), when
    /// the file is the slow-motion version.
    var slowStart: Double? = nil
    var slowEnd: Double? = nil
    var speed: Double? = nil

    init(clipStart: Double, slowMo: (speed: SlowMoSpeed, segment: SlowMoSegment)? = nil) {
        self.clipStart = clipStart
        if let slowMo {
            slowStart = slowMo.segment.start
            slowEnd = slowMo.segment.end
            speed = slowMo.speed.rawValue
        }
    }

    /// Game-video seconds to seconds in the file.
    func fileTime(_ gameTime: Double) -> Double {
        let clipTime = gameTime - clipStart
        guard let slowStart, let slowEnd, let speed, speed > 0 else { return clipTime }
        if clipTime <= slowStart { return clipTime }
        if clipTime <= slowEnd { return slowStart + (clipTime - slowStart) / speed }
        return clipTime + (slowEnd - slowStart) * (1 / speed - 1)
    }

    /// Seconds in the file to game-video seconds.
    func gameTime(_ fileTime: Double) -> Double {
        guard let slowStart, let slowEnd, let speed, speed > 0 else { return fileTime + clipStart }
        let stretchedEnd = slowStart + (slowEnd - slowStart) / speed
        let clipTime: Double
        if fileTime <= slowStart {
            clipTime = fileTime
        } else if fileTime <= stretchedEnd {
            clipTime = slowStart + (fileTime - slowStart) * speed
        } else {
            clipTime = fileTime - (slowEnd - slowStart) * (1 / speed - 1)
        }
        return clipTime + clipStart
    }
}
