import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Times making a clip and trimming it on real footage (decision 0023). Skipped unless
/// `COURTSIDE_TIMING_SOURCES` names one or more videos (comma-separated; pass it to `xcodebuild` as
/// `TEST_RUNNER_COURTSIDE_TIMING_SOURCES`). Each source is imported (copied) as a game, one tap in the
/// middle makes a 13 s clip through `ClipExtractor`, and the clip is trimmed out by 2 s on each side,
/// once at each "Clip quality".
/// Sources are read only; everything a run creates is removed. Results print as `QUALITY|` lines.
@MainActor
final class ClipQualityTimingTests: XCTestCase {
    func testClipAndTrimTimes() async throws {
        let list = ProcessInfo.processInfo.environment["COURTSIDE_TIMING_SOURCES"] ?? ""
        let sources = list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_TIMING_SOURCES to time clips and trims on real footage.")
        }
        let saved = UserDefaults.standard.object(forKey: ClipSettings.qualityKey)
        defer { UserDefaults.standard.set(saved, forKey: ClipSettings.qualityKey) }
        for source in sources {
            for quality in [ClipQuality.hd1080, .full] {
                UserDefaults.standard.set(quality.rawValue, forKey: ClipSettings.qualityKey)
                try await time(source, quality: quality)
            }
        }
    }

    private func time(_ source: URL, quality: ClipQuality) async throws {
        let name = "\(source.lastPathComponent)|\(quality.title)"
        StorageManager.prepareDirectories()
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let before = FileSnapshot.take()
        var game: Game?
        defer {
            if let game, game.modelContext != nil { StorageManager.deleteGame(game, in: context) }
            FileSnapshot.take().added(since: before).forEach(StorageManager.removeFile(at:))
        }

        let imported = try await VideoImporter.importFromFile(at: source) { _ in }
        let newGame = Game(id: imported.videoID, label: "", recordedAt: .now, videoFilename: imported.filename,
                           durationSeconds: imported.durationSeconds, source: .imported, videoFileSize: imported.fileSize)
        context.insert(newGame)
        game = newGame
        let part = try XCTUnwrap(newGame.orderedParts.first)
        let mark = Mark(offsetSeconds: imported.durationSeconds / 2)
        context.insert(mark)
        mark.game = newGame
        mark.part = part
        try context.save()

        let extractor = ClipExtractor()
        let clipTime = try await measure {
            XCTAssertTrue(extractor.start(game: newGame, context: context))
            while extractor.phase == .running { try await Task.sleep(for: .milliseconds(100)) }
        }
        let clip = try XCTUnwrap(newGame.clips.first, "\(name): clip made")
        await report(name, "make 13 s clip", clipTime, clip.fileURL)

        let bounds = ClipWindow.trimBounds(mark: clip.markTime, gameDuration: part.durationSeconds, current: clip.window)
        let wider = clip.window.trimming(.start, to: clip.startSeconds - 2, within: bounds)
            .trimming(.end, to: clip.endSeconds + 2, within: bounds)
        let trimTime = try await measure { try await ClipExtractor.trim(clip, to: wider, context: context) { _ in } }
        await report(name, String(format: "trim to %.0f s", wider.duration), trimTime, clip.fileURL)
    }

    private func measure(_ body: () async throws -> Void) async throws -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func report(_ source: String, _ what: String, _ seconds: Double, _ file: URL) async {
        let detail = await LabelExportTimingTests.describe(file)
        let length = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        print("QUALITY|\(source)|\(what)|\(String(format: "%.1f", seconds))|\(detail), \(String(format: "%.2f", length)) s")
    }
}
