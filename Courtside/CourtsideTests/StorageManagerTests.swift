import XCTest
@testable import Courtside

final class StorageManagerTests: XCTestCase {
    func testStoresRelativeFilenamesAndRebuildsURLs() {
        let id = UUID()
        let filename = StorageManager.makeGameVideoFilename(id: id, fileExtension: "mp4")
        XCTAssertEqual(filename, "\(id.uuidString).mp4")
        XCTAssertFalse(filename.contains("/"))
        XCTAssertEqual(StorageManager.gameVideoURL(filename: filename).deletingLastPathComponent().lastPathComponent, "Games")
        XCTAssertEqual(StorageManager.clipURL(filename: "x.mov").deletingLastPathComponent().lastPathComponent, "Clips")
    }

    func testPartialURLKeepsExtension() {
        let url = StorageManager.clipURL(filename: "ABC.mov")
        XCTAssertEqual(StorageManager.partialURL(for: url).lastPathComponent, "ABC.partial.mov")
    }

    func testDirectoriesAreExcludedFromBackup() throws {
        StorageManager.prepareDirectories()
        for directory in [StorageManager.gamesDirectory, StorageManager.clipsDirectory] {
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, directory.lastPathComponent)
        }
    }
}
