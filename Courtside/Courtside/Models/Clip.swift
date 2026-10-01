import Foundation
import SwiftData

@Model final class Clip {
    var id: UUID
    /// Relative filename only. Rebuild the URL through `StorageManager`.
    var filename: String
    /// Window in the source game video.
    var startSeconds: Double
    var endSeconds: Double
    var createdAt: Date
    var fileSize: Int64
    /// Where the parent tapped, in game-video seconds. Nil for clips made before this was stored.
    var markSeconds: Double?
    /// Slow-motion render. All nil = not rendered. Relative filename only.
    var slowMoFilename: String?
    var slowMoSpeed: Double?
    /// Slow segment, in seconds on the clip's own timeline.
    var slowMoStartSeconds: Double?
    var slowMoEndSeconds: Double?
    var slowMoFileSize: Int64?
    var game: Game?

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

    var hasSlowMo: Bool { slowMoFilename != nil }

    var slowMoURL: URL? { slowMoFilename.map(StorageManager.clipURL(filename:)) }

    var slowMo: (speed: SlowMoSpeed, segment: SlowMoSegment)? {
        guard hasSlowMo,
              let raw = slowMoSpeed, let speed = SlowMoSpeed(rawValue: raw),
              let start = slowMoStartSeconds, let end = slowMoEndSeconds
        else { return nil }
        return (speed, SlowMoSegment(start: start, end: end))
    }
}
