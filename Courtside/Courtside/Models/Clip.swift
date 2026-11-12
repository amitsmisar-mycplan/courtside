import Foundation
import SwiftData

@Model final class Clip {
    var id: UUID
    /// Relative filename only. Rebuild the URL through `StorageManager`.
    var filename: String
    /// Window in its part's video.
    var startSeconds: Double
    var endSeconds: Double
    var createdAt: Date
    var fileSize: Int64
    /// Where the parent tapped, in seconds of its part's video. Nil for clips made before this was stored.
    var markSeconds: Double?
    /// Slow-motion render. All nil = not rendered. Relative filename only.
    var slowMoFilename: String?
    var slowMoSpeed: Double?
    /// Slow segment, in seconds on the clip's own timeline.
    var slowMoStartSeconds: Double?
    var slowMoEndSeconds: Double?
    var slowMoFileSize: Int64?
    /// Vertical aim points as JSON (decision 0028); nil is one centered aim. Use `aimTrack`.
    var aimTrackData: Data?
    var game: Game?
    /// The video this clip was cut from (decision 0022). Use `resolvedPart`.
    var part: GamePart?

    init(
        id: UUID = UUID(),
        filename: String,
        startSeconds: Double,
        endSeconds: Double,
        createdAt: Date = .now,
        fileSize: Int64,
        markSeconds: Double? = nil
    ) {
        self.id = id
        self.filename = filename
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.markSeconds = markSeconds
    }
}

extension Clip {
    var window: ClipWindow { ClipWindow(start: startSeconds, end: endSeconds) }
    var fileURL: URL { StorageManager.clipURL(for: self) }

    /// The tap's position on the clip's own timeline. Clips made before `markSeconds` was
    /// stored assume the default post-roll, which is exact for unedited clips.
    var markInClip: Double {
        let duration = window.duration
        let mark = markSeconds.map { $0 - startSeconds } ?? duration - ClipWindow.defaultPostRoll
        return min(max(mark, 0), duration)
    }

    /// The tap, in game-video seconds. Clips made before `markSeconds` was stored infer it.
    var markTime: Double { markSeconds ?? startSeconds + markInClip }

    /// The clip as the tap plus offsets (decision 0015): seconds kept before and after the tap.
    var secondsBeforeMark: Double { markTime - startSeconds }
    var secondsAfterMark: Double { endSeconds - markTime }

    var hasSlowMo: Bool { slowMoFilename != nil }

    /// Its part, or Part 1 for a record not yet given one (before the parts migration ran).
    var resolvedPart: GamePart? { part ?? game?.orderedParts.first }

    /// Where Vertical exports point over time (decision 0028). Nil is one centered aim, as before.
    var aimTrack: AimTrack? {
        get { aimTrackData.flatMap(AimTrack.decode) }
        set { aimTrackData = newValue?.encoded() }
    }

    var slowMoURL: URL? { slowMoFilename.map(StorageManager.clipURL(filename:)) }

    var slowMo: (speed: SlowMoSpeed, segment: SlowMoSegment)? {
        guard hasSlowMo,
              let raw = slowMoSpeed, let speed = SlowMoSpeed(rawValue: raw),
              let start = slowMoStartSeconds, let end = slowMoEndSeconds
        else { return nil }
        return (speed, SlowMoSegment(start: start, end: end))
    }
}
