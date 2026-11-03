import Foundation
import SwiftData

@Model final class Mark {
    var id: UUID
    /// Seconds from the start of its part's video.
    var offsetSeconds: Double
    var createdAt: Date
    /// True once a clip has been made from this mark (or it was skipped as unextractable).
    var isExtracted: Bool
    var game: Game?
    /// The video this mark is in (decision 0022). Use `resolvedPart`.
    var part: GamePart?

    init(id: UUID = UUID(), offsetSeconds: Double, createdAt: Date = .now) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.createdAt = createdAt
        self.isExtracted = false
    }
}

extension Mark {
    /// Its part, or Part 1 for a record not yet given one (before the parts migration ran).
    var resolvedPart: GamePart? { part ?? game?.orderedParts.first }
}
