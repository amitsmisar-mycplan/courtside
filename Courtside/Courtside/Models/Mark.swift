import Foundation
import SwiftData

@Model final class Mark {
    var id: UUID
    /// Seconds from the start of the game video.
    var offsetSeconds: Double
    var createdAt: Date
    /// True once a clip has been made from this mark (or it was skipped as unextractable).
    var isExtracted: Bool
    var game: Game?

    init(id: UUID = UUID(), offsetSeconds: Double, createdAt: Date = .now) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.createdAt = createdAt
        self.isExtracted = false
    }
}
