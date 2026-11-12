import AVFoundation
import XCTest
@testable import Courtside

/// "Find Moments" on real footage (decision 0029). Skipped unless `COURTSIDE_CORPUS_DIR` names a
/// folder of videos (pass it to `xcodebuild` as `TEST_RUNNER_COURTSIDE_CORPUS_DIR`). Each video's
/// sound is read in place, never copied or changed. Prints one `MOMENTS|` line per video: length,
/// listening time per minute of video, and the suggested times, to compare against your own marks.
final class FindMomentsCorpusTests: XCTestCase {
    func testSuggestionsOnCorpus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["COURTSIDE_CORPUS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_CORPUS_DIR to list suggested moments for real footage.")
        }
        let labels = Set(try MomentListener.availableLabels())
        let used = MomentListener.groups.flatMap(\.1)
        print("MOMENTS|classifier|\(labels.count) labels|used: \(used.map { labels.contains($0) ? $0 : "\($0) (missing)" }.joined(separator: ", "))")
        XCTAssertTrue(used.allSatisfy(labels.contains), "every label Find Moments listens for is offered")

        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let videos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(videos.isEmpty, "no videos in \(directory)")

        var totalAudio = 0.0, totalTime = 0.0, totalFound = 0
        for url in videos {
            let started = Date()
            let result: MomentListener.Result
            do {
                result = try await MomentListener.listen(to: url, progress: { _ in }, checkpoint: { _ in })
            } catch {
                print("MOMENTS|\(url.lastPathComponent)|skipped: \(error.localizedDescription)")
                continue
            }
            let listening = Date().timeIntervalSince(started)
            let found = MomentPicker.pick(result.signal, avoiding: [])
            let minutes = Double(result.signal.count) / 60
            totalAudio += minutes
            totalTime += listening
            totalFound += found.count
            let list = found.map { "\(Format.duration($0.seconds)) \($0.sound.rawValue) \(String(format: "%.1f", $0.score))" }
            print(String(format: "MOMENTS|%@|%.1f min|%.1f s|%.2f s per min|%d found|", url.lastPathComponent, minutes,
                         listening, minutes > 0 ? listening / minutes : 0, found.count) + list.joined(separator: ", "))
            XCTAssertTrue(result.isComplete)
        }
        print(String(format: "MOMENTS|total|%.1f min|%.1f s|%.2f s per min|%d found", totalAudio, totalTime,
                     totalAudio > 0 ? totalTime / totalAudio : 0, totalFound))
    }
}
