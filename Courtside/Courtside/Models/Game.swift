import Foundation
import SwiftData

enum GameSource: String, Codable {
    case imported
    case recorded

    /// Display only. Nothing downstream of game creation branches on source.
    var displayName: String {
        switch self {
        case .imported: "Imported"
        case .recorded: "Recorded"
        }
    }
}

@Model final class Game {
    var id: UUID
    var label: String
    var recordedAt: Date
    /// Relative filename only. Rebuild the URL through `StorageManager`.
    var videoFilename: String
    var durationSeconds: Double
    var source: GameSource
    var isProcessed: Bool
    /// Size of the full game video, captured at creation so views never stat files.
    var videoFileSize: Int64
    /// False once the full game video has been deleted (by the user or the 7-day cleanup).
    var isVideoAvailable: Bool
    /// When clips were last extracted. Starts the 7-day auto-delete clock for the full video.
    var processedAt: Date?
    /// The parent answered "Keep" to the full-video prompt, so it's never auto-deleted.
    var keepsVideo: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
    @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]

    init(
        id: UUID = UUID(),
        label: String,
        recordedAt: Date,
        videoFilename: String,
        durationSeconds: Double,
        source: GameSource,
        videoFileSize: Int64
    ) {
        self.id = id
        self.label = label
        self.recordedAt = recordedAt
        self.videoFilename = videoFilename
        self.durationSeconds = durationSeconds
        self.source = source
        self.isProcessed = false
        self.videoFileSize = videoFileSize
        self.isVideoAvailable = true
        self.processedAt = nil
        self.marks = []
        self.clips = []
    }
}

extension Game {
    static let videoRetention: TimeInterval = 7 * 24 * 60 * 60

    static func defaultLabel(for date: Date) -> String {
        "Game — \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Marks that don't have a clip yet.
    var pendingMarks: [Mark] {
        marks.filter { !$0.isExtracted }.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }

    var sortedClips: [Clip] {
        clips.sorted { $0.startSeconds < $1.startSeconds }
    }

    var clipsStorageBytes: Int64 {
        clips.reduce(0) { $0 + $1.fileSize + ($1.slowMoFileSize ?? 0) }
    }

    var storageBytes: Int64 {
        (isVideoAvailable ? videoFileSize : 0) + clipsStorageBytes
    }

    /// When the launch-time cleanup will delete the full video, if ever. Only videos whose
    /// keep/delete prompt went unanswered expire.
    var videoExpiresAt: Date? {
        guard isVideoAvailable, !keepsVideo, let processedAt else { return nil }
        return processedAt.addingTimeInterval(Self.videoRetention)
    }
}
