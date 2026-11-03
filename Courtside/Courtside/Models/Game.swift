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
    /// When the game was played: Part 1's creation date on import, the start time when recording. Editable.
    /// Adding a part doesn't change it (decision 0022).
    var recordedAt: Date
    var source: GameSource
    /// Every mark, in every part, has its clip.
    var isProcessed: Bool
    /// The parent answered "Keep" to the full-video prompt, so no part's video is ever auto-deleted.
    /// Game-wide: it covers parts added later too (decision 0022).
    var keepsVideo: Bool = false
    /// Game details, all optional and filled in whenever the parent gets to it (decision 0013).
    var opponent: String?
    var ourScore: Int?
    var theirScore: Int?
    var notes: String?
    /// Our team and the tournament, optional (decision 0019). Team starts from the "My team" setting.
    var team: String?
    var tournament: String?
    @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
    @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]
    /// The game's videos (decision 0022). Use `orderedParts`.
    @Relationship(deleteRule: .cascade, inverse: \GamePart.game) var parts: [GamePart] = []

    // Before decision 0022 a game held one video. These keep that video's details as stored then;
    // new games write Part 1's values here too. Only the parts migration and orphan recovery's list
    // of known files read them. Use the parts for everything else.
    @Attribute(originalName: "videoFilename") var legacyVideoFilename: String
    @Attribute(originalName: "durationSeconds") var legacyDurationSeconds: Double
    @Attribute(originalName: "videoFileSize") var legacyVideoFileSize: Int64
    @Attribute(originalName: "isVideoAvailable") var legacyIsVideoAvailable: Bool
    @Attribute(originalName: "processedAt") var legacyProcessedAt: Date?

    /// A new game with its first video as Part 1.
    init(
        id: UUID = UUID(),
        label: String,
        recordedAt: Date,
        videoFilename: String,
        durationSeconds: Double,
        source: GameSource,
        videoFileSize: Int64,
        team: String? = nil
    ) {
        self.id = id
        self.label = label
        self.recordedAt = recordedAt
        self.source = source
        self.isProcessed = false
        self.team = team
        self.legacyVideoFilename = videoFilename
        self.legacyDurationSeconds = durationSeconds
        self.legacyVideoFileSize = videoFileSize
        self.legacyIsVideoAvailable = true
        self.legacyProcessedAt = nil
        self.marks = []
        self.clips = []
        self.parts = [GamePart(
            index: 0, videoFilename: videoFilename, durationSeconds: durationSeconds,
            videoFileSize: videoFileSize, recordedAt: recordedAt
        )]
    }
}

extension Game {
    static let videoRetention: TimeInterval = 7 * 24 * 60 * 60

    static let untitled = "Untitled game"

    /// Row and screen title: "<team> vs <opponent>" when both are set, else "vs <opponent>", else the
    /// name, else "Untitled game".
    var displayTitle: String {
        if let opponent = opponent?.nonEmpty {
            if let team = team?.nonEmpty { return "\(team) vs \(opponent)" }
            return "vs \(opponent)"
        }
        let name = label.trimmed
        return name.isEmpty ? Self.untitled : name
    }

    /// Row subtitle: "<tournament> · <date>", or just the date.
    var listSubtitle: String {
        let date = recordedAt.formatted(date: .abbreviated, time: .shortened)
        guard let tournament = tournament?.nonEmpty else { return date }
        return "\(tournament) · \(date)"
    }

    /// "54–48" (us first), with "?" for a side not entered yet; nil when neither is set.
    var scoreText: String? {
        guard ourScore != nil || theirScore != nil else { return nil }
        let side = { (score: Int?) in score.map(String.init) ?? "?" }
        return "\(side(ourScore))–\(side(theirScore))"
    }

    // MARK: Parts

    /// In the order they were added.
    var orderedParts: [GamePart] {
        parts.sorted { $0.index < $1.index }
    }

    var hasSeveralParts: Bool { parts.count > 1 }

    /// The index the next added video gets.
    var nextPartIndex: Int { (parts.map(\.index).max() ?? -1) + 1 }

    /// Total length of every part's video.
    var durationSeconds: Double {
        parts.reduce(0) { $0 + $1.durationSeconds }
    }

    /// True while any part's video is still on the phone.
    var isVideoAvailable: Bool {
        parts.contains(where: \.isVideoAvailable)
    }

    /// Size of the videos still on the phone.
    var availableVideoBytes: Int64 {
        parts.filter(\.isVideoAvailable).reduce(0) { $0 + $1.videoFileSize }
    }

    /// Parts whose video the keep/delete prompt's "Delete" removes: available, with every mark made
    /// into a clip. A part added but not yet marked is never deleted by it (decision 0022).
    var processedAvailableParts: [GamePart] {
        orderedParts.filter { $0.isVideoAvailable && $0.isProcessed }
    }

    /// The soonest a part's video will be auto-deleted, if any part's will.
    var videoExpiresAt: Date? {
        parts.compactMap(\.videoExpiresAt).min()
    }

    // MARK: Marks and clips

    /// Marks that don't have a clip yet, in part order, then time.
    var pendingMarks: [Mark] {
        marks.filter { !$0.isExtracted }.sorted(by: Self.partThenTime)
    }

    /// Pending marks whose part video is still there to cut from.
    var extractableMarks: [Mark] {
        pendingMarks.filter { $0.resolvedPart?.isVideoAvailable == true }
    }

    /// In part order, then time.
    var sortedClips: [Clip] {
        clips.sorted {
            let (a, b) = ($0.resolvedPart?.index ?? 0, $1.resolvedPart?.index ?? 0)
            return a != b ? a < b : $0.startSeconds < $1.startSeconds
        }
    }

    var clipsStorageBytes: Int64 {
        clips.reduce(0) { $0 + $1.fileSize + ($1.slowMoFileSize ?? 0) }
    }

    var storageBytes: Int64 {
        availableVideoBytes + clipsStorageBytes
    }

    private static func partThenTime(_ a: Mark, _ b: Mark) -> Bool {
        let (left, right) = (a.resolvedPart?.index ?? 0, b.resolvedPart?.index ?? 0)
        return left != right ? left < right : a.offsetSeconds < b.offsetSeconds
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Trimmed, or nil when nothing is left.
    var nonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
