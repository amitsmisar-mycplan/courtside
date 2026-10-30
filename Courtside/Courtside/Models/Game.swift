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
    /// Optional free-text name. Empty for new games; rows fall back to the opponent, then "Untitled game".
    var label: String
    /// When the game was played: the video's creation date on import, the start time when recording. Editable.
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
    /// Game details, all optional and filled in whenever the parent gets to it (decision 0013).
    var opponent: String?
    var ourScore: Int?
    var theirScore: Int?
    var notes: String?
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

    static let untitled = "Untitled game"

    /// Row and screen title: "vs <opponent>", else the name, else "Untitled game".
    var displayTitle: String {
        if let opponent = opponent?.trimmed, !opponent.isEmpty { return "vs \(opponent)" }
        let name = label.trimmed
        return name.isEmpty ? Self.untitled : name
    }

    /// "54–48" (us first), with "?" for a side not entered yet; nil when neither is set.
    var scoreText: String? {
        guard ourScore != nil || theirScore != nil else { return nil }
        let side = { (score: Int?) in score.map(String.init) ?? "?" }
        return "\(side(ourScore))–\(side(theirScore))"
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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
