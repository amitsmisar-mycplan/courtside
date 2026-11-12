import Foundation
import SwiftData

/// One video of a game (decision 0022). A game has one part per video, in the order they were
/// added: "Part 1", "Part 2". Marks and clips point to their part, and their times are seconds
/// in that part's video.
@Model final class GamePart {
    var id: UUID
    /// 0-based position, the order the video was added. Shown as "Part \(index + 1)".
    var index: Int
    /// Relative filename only. Rebuild the URL through `StorageManager`.
    var videoFilename: String
    var durationSeconds: Double
    /// Captured at import or when recording stops, so views never stat files.
    var videoFileSize: Int64
    /// When this video was filmed (its creation date, or the recording start).
    var recordedAt: Date
    /// False once this part's video has been deleted (by the parent or the 7-day cleanup) or found missing.
    var isVideoAvailable: Bool
    /// When clips were last made from this part. Starts this part's 7-day auto-delete clock.
    var processedAt: Date?
    /// When "Find Moments" last finished listening to this video (decision 0029); nil if never.
    var momentsFoundAt: Date?
    var game: Game?
    @Relationship(deleteRule: .nullify, inverse: \Mark.part) var marks: [Mark]
    @Relationship(deleteRule: .nullify, inverse: \Clip.part) var clips: [Clip]
    /// "Find Moments" results (decision 0029); they go with the part.
    @Relationship(deleteRule: .cascade, inverse: \SuggestedMoment.part) var suggestions: [SuggestedMoment] = []

    init(
        id: UUID = UUID(),
        index: Int,
        videoFilename: String,
        durationSeconds: Double,
        videoFileSize: Int64,
        recordedAt: Date
    ) {
        self.id = id
        self.index = index
        self.videoFilename = videoFilename
        self.durationSeconds = durationSeconds
        self.videoFileSize = videoFileSize
        self.recordedAt = recordedAt
        self.isVideoAvailable = true
        self.processedAt = nil
        self.marks = []
        self.clips = []
    }
}

extension GamePart {
    var title: String { "Part \(index + 1)" }

    /// Every mark in this part has its clip, and clips have been made from it.
    var isProcessed: Bool {
        processedAt != nil && marks.allSatisfy(\.isExtracted)
    }

    /// When the launch-time cleanup will delete this part's video, if ever: 7 days after its own
    /// clips were made, unless the game is kept. A part never processed never expires.
    var videoExpiresAt: Date? {
        guard isVideoAvailable, game?.keepsVideo != true, let processedAt else { return nil }
        return processedAt.addingTimeInterval(Game.videoRetention)
    }
}
