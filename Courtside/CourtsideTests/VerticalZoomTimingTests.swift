import AVFoundation
import XCTest
@testable import Courtside

/// Times labelled Vertical exports at each zoom on real footage (decision 0024). Skipped unless
/// `COURTSIDE_TIMING_SOURCES` names one or more videos (pass it to `xcodebuild` as
/// `TEST_RUNNER_COURTSIDE_TIMING_SOURCES`). A 13 s clip is cut from the middle of each source at
/// full quality into a temporary folder, then saved Vertical with the label at today's layout and
/// at zoom 0, 60 % and 100 % (held to the quality limit). Sources are read only; everything made
/// is removed. Results print as `ZOOM|` lines.
@MainActor
final class VerticalZoomTimingTests: XCTestCase {
    func testVerticalZoomExportTimes() async throws {
        let list = ProcessInfo.processInfo.environment["COURTSIDE_TIMING_SOURCES"] ?? ""
        let sources = list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_TIMING_SOURCES to time Vertical zoom exports on real footage.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "zoom-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)

        for source in sources {
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            let start = max(0, duration / 2 - 6.5)
            let clip = work.appending(path: "clip.mov")
            try await ClipExtractor.export(source: source, window: ClipWindow(start: start, end: start + 13), to: clip, quality: .full) { _ in }
            let size = try await SlowMoComposer.displaySize(of: clip)
            let cases: [(String, VerticalFraming?)] = [
                ("today (no zoom)", nil),
                ("zoom 0 %", VerticalFraming(zoom: 0)),
                ("zoom 60 %", VerticalFraming(zoom: 0.6)),
                ("zoom 100 %", VerticalFraming(zoom: 1)),
            ]
            for (name, framing) in cases {
                let output = work.appending(path: "vertical.mov")
                let plan = ExportPlan(source: clip, format: .vertical, label: label, quality: .hd1080, framing: framing)
                let begin = ContinuousClock.now
                try await ClipExtractor.exportForSharing(plan, to: output) { _ in }
                let elapsed = ContinuousClock.now - begin
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let shown = framing.map { Int(($0.clamped(videoSize: size).zoom * 100).rounded()) }.map { " (used \($0) %)" } ?? ""
                let detail = await LabelExportTimingTests.describe(output)
                print("ZOOM|\(source.lastPathComponent) \(Int(size.width))×\(Int(size.height))|\(name)\(shown)|\(String(format: "%.1f", seconds))|\(detail)")
                try? FileManager.default.removeItem(at: output)
            }
            try? FileManager.default.removeItem(at: clip)
        }
    }
}
