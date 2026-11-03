import Foundation
import UIKit

/// Grants time to keep working after the app leaves the screen. Injected so tests can make the
/// time run out on demand.
@MainActor protocol BackgroundTimeGranting {
    /// `onExpiry` runs on the main thread when iOS is about to suspend the app.
    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ task: UIBackgroundTaskIdentifier)
}

/// The real thing: `UIApplication` background tasks.
struct SystemBackgroundTime: BackgroundTimeGranting {
    nonisolated init() {}

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { onExpiry() }
        }
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Games whose clip-making was cut off by the system (background time ran out, or the app was
/// closed mid-run) rather than stopped by the parent. Kept in UserDefaults so the list survives
/// the app being killed; the marks themselves stay pending in SwiftData (decision 0017).
struct UnfinishedClips {
    static let key = "unfinishedClipGameIDs"

    var defaults: UserDefaults = .standard

    var gameIDs: [UUID] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:))
    }

    func add(_ id: UUID) {
        guard !gameIDs.contains(id) else { return }
        save(gameIDs + [id])
    }

    func remove(_ id: UUID) {
        save(gameIDs.filter { $0 != id })
    }

    /// Games still waiting for clips, in the order they were cut off. Entries with nothing left
    /// to do (game deleted, video deleted, every mark has its clip) are dropped from the list.
    @MainActor func gamesToFinish(from games: [Game]) -> [Game] {
        var waiting: [Game] = []
        for id in gameIDs {
            // Pending marks in a part whose video is still there, in any part (decision 0022).
            if let game = games.first(where: { $0.id == id }), !game.extractableMarks.isEmpty {
                waiting.append(game)
            } else {
                remove(id)
            }
        }
        return waiting
    }

    private func save(_ ids: [UUID]) {
        defaults.set(ids.map(\.uuidString), forKey: Self.key)
    }
}
