import Foundation
import SwiftData

/// A moment "Find Moments" heard the crowd react to, waiting for the parent to accept or dismiss it
/// (decision 0029). Accepting makes an ordinary `Mark`; a suggestion never becomes a clip by itself.
@Model final class SuggestedMoment {
    enum Status: String, Codable {
        case pending
        case accepted
        case dismissed
    }

    /// What was loudest in the crowd at that moment, for the row's caption.
    enum Sound: String, Codable {
        case cheering
        case applause
        case shouting
        case crowd
        /// Only the loudness stood out; the classifier heard nothing crowd-like.
        case loud
    }

    var id: UUID
    /// Seconds from the start of its part's video, like `Mark.offsetSeconds`: where a mark goes
    /// when the parent accepts it.
    var seconds: Double
    /// How strongly it stood out from the rest of its video. Only compares suggestions in one part.
    var score: Double
    var status: Status
    var sound: Sound
    var createdAt: Date
    /// The mark Accept made, so Undo can remove it while it has no clip yet.
    var markID: UUID?
    var part: GamePart?

    init(id: UUID = UUID(), seconds: Double, score: Double, sound: Sound, createdAt: Date = .now) {
        self.id = id
        self.seconds = seconds
        self.score = score
        self.status = .pending
        self.sound = sound
        self.createdAt = createdAt
    }
}

extension SuggestedMoment {
    /// The mark Accept made, while it still exists.
    var acceptedMark: Mark? {
        guard status == .accepted, let markID else { return nil }
        return part?.game?.marks.first { $0.id == markID }
    }

    /// Accepted and its mark has no clip yet, or dismissed: Undo puts it back in the list.
    var canUndo: Bool {
        switch status {
        case .pending: false
        case .dismissed: true
        case .accepted: acceptedMark.map { !$0.isExtracted } ?? false
        }
    }

    /// Adds an ordinary mark at this moment, so the normal clip pipeline makes its clip. Returns
    /// the mark, or nil when the moment isn't pending or its part's video is gone.
    @MainActor @discardableResult
    func accept(in context: ModelContext) -> Mark? {
        guard status == .pending, let part, part.isVideoAvailable, let game = part.game else { return nil }
        let mark = Mark(offsetSeconds: min(max(seconds, 0), part.durationSeconds))
        context.insert(mark)
        mark.game = game
        mark.part = part
        game.isProcessed = false
        status = .accepted
        markID = mark.id
        try? context.save()
        return mark
    }

    @MainActor func dismiss(in context: ModelContext) {
        guard status == .pending else { return }
        status = .dismissed
        try? context.save()
    }

    /// Back to pending. An accepted moment's mark is removed with it, unless its clip is made.
    @MainActor func undo(in context: ModelContext) {
        guard canUndo else { return }
        if let mark = acceptedMark, let game = mark.game {
            context.delete(mark)
            game.isProcessed = game.marks.allSatisfy { $0.id == mark.id || $0.isExtracted }
        }
        status = .pending
        markID = nil
        try? context.save()
    }
}

extension GamePart {
    /// In time order.
    var orderedSuggestions: [SuggestedMoment] {
        suggestions.sorted { $0.seconds < $1.seconds }
    }

    var pendingSuggestionCount: Int {
        suggestions.filter { $0.status == .pending }.count
    }
}
