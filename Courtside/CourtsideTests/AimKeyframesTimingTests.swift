import AVFoundation
import XCTest
@testable import Courtside

/// Times Vertical exports with three aim points against one static aim on real footage
/// (decision 0028). Skipped unless `COURTSIDE_TIMING_SOURCES` names one or more videos (pass it
/// to `xcodebuild` as `TEST_RUNNER_COURTSIDE_TIMING_SOURCES`). A 13 s clip is cut from the middle
/// of each source at the default "Clip quality" (1080p) into a temporary folder, then saved
/// Vertical at 60 % zoom, with and without the label. Sources are read only; everything made is
/// removed. Results print as `AIM|` lines.
@MainActor
final class AimKeyframesTimingTests: XCTestCase {
    func testAimKeyframeExportTimes() async throws {
        let list = ProcessInfo.processInfo.environment["COURTSIDE_TIMING_SOURCES"] ?? ""
        let sources = list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_TIMING_SOURCES to time aim-point exports on real footage.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "aim-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)
        let points = AimPath(keys: [
            AimPath.Key(time: 1, center: CGPoint(x: 0.2, y: 0.5)),
            AimPath.Key(time: 6, center: CGPoint(x: 0.8, y: 0.5)),
            AimPath.Key(time: 11, center: CGPoint(x: 0.5, y: 0.5)),
        ])

        for source in sources {
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            let start = max(0, duration / 2 - 6.5)
            let clip = work.appending(path: "clip.mov")
            try await ClipExtractor.export(source: source, window: ClipWindow(start: start, end: start + 13), to: clip, quality: .hd1080) { _ in }
            let size = try await SlowMoComposer.displaySize(of: clip)
            let cases: [(String, LabelStep.LabelText?, AimPath?)] = [
                ("static, label", label, nil),
                ("3 points, label", label, points),
                ("static, no label", nil, nil),
                ("3 points, no label", nil, points),
            ]
            for (name, caseLabel, aim) in cases {
                let output = work.appending(path: "vertical.mov")
                let plan = ExportPlan(source: clip, format: .vertical, label: caseLabel, quality: .hd1080,
                                      framing: VerticalFraming(zoom: 0.6), aim: aim)
                let begin = ContinuousClock.now
                try await ClipExtractor.exportForSharing(plan, to: output) { _ in }
                let elapsed = ContinuousClock.now - begin
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let detail = await LabelExportTimingTests.describe(output)
                print("AIM|\(source.lastPathComponent) \(Int(size.width))×\(Int(size.height))|\(name)|\(String(format: "%.1f", seconds))|\(detail)")
                try? FileManager.default.removeItem(at: output)
            }
            try? FileManager.default.removeItem(at: clip)
        }
    }
}
