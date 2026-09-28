import SwiftData
import SwiftUI

@main
struct CourtsideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer

    init() {
        StorageManager.prepareDirectories()
        do {
            container = try ModelContainer(for: Game.self, Mark.self, Clip.self)
        } catch {
            fatalError("Could not open the game database: \(error)")
        }
        StorageManager.performLaunchCleanup(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            GamesListView()
        }
        .modelContainer(container)
    }
}
