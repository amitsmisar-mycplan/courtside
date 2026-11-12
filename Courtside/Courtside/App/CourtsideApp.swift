import SwiftData
import SwiftUI

@main
struct CourtsideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer

    init() {
        StorageManager.prepareDirectories()
        // Before the parts schema first opens the store (decision 0022).
        StorageManager.backUpStoreBeforeParts(storeURL: ModelConfiguration().url)
        do {
            container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self)
        } catch {
            fatalError("Could not open the game database: \(error)")
        }
        // Games from before parts get their Part 1 before anything reads parts.
        StorageManager.migrateToParts(in: container.mainContext)
        // Unit tests run inside this app and create and delete their own files in Documents;
        // launch maintenance mustn't race them (it would "recover" test videos as games).
        guard !AppEnvironment.isUnitTesting else { return }
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

enum AppEnvironment {
    /// Unit tests run hosted inside the app, sharing its files and settings.
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
