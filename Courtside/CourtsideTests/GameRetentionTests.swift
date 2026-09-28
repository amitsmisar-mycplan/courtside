import XCTest
@testable import Courtside

final class GameRetentionTests: XCTestCase {
    private func makeGame() -> Game {
        Game(
            label: "Test",
            recordedAt: .now,
            videoFilename: "x.mov",
            durationSeconds: 600,
            source: .imported,
            videoFileSize: 1
        )
    }

    func testUnprocessedGameNeverExpires() {
        XCTAssertNil(makeGame().videoExpiresAt)
    }

    func testUnansweredPromptExpiresSevenDaysAfterProcessing() {
        let game = makeGame()
        let processedAt = Date(timeIntervalSince1970: 1_000_000)
        game.processedAt = processedAt
        XCTAssertEqual(game.videoExpiresAt, processedAt.addingTimeInterval(7 * 24 * 60 * 60))
    }

    func testKeptVideoNeverExpires() {
        let game = makeGame()
        game.processedAt = .now
        game.keepsVideo = true
        XCTAssertNil(game.videoExpiresAt)
    }

    func testDeletedVideoHasNoExpiry() {
        let game = makeGame()
        game.processedAt = .now
        game.isVideoAvailable = false
        XCTAssertNil(game.videoExpiresAt)
    }
}
