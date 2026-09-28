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
    var game: Game?

    init(
        id: UUID = UUID(),
        filename: String,
        startSeconds: Double,
        endSeconds: Double,
        createdAt: Date = .now,
        fileSize: Int64
    ) {
        self.id = id
        self.filename = filename
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.createdAt = createdAt
        self.fileSize = fileSize
    }
}

extension Clip {
    var window: ClipWindow { ClipWindow(start: startSeconds, end: endSeconds) }
    var fileURL: URL { StorageManager.clipURL(for: self) }
}
