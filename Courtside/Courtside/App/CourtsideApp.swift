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
        // Unit tests run inside this app and create and delete their own files in Documents;
        // launch maintenance mustn't race them (it would "recover" test videos as games).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        StorageManager.performLaunchCleanup(in: container.mainContext)
        let context = container.mainContext
        Task { await StorageManager.recoverRecordings(in: context) }
    }

    var body: some Scene {
        WindowGroup {
            GamesListView()
        }
        .modelContainer(container)
    }
}
