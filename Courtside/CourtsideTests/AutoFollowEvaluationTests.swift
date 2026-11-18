import AVFoundation
import XCTest
@testable import Courtside

/// Auto-follow against the fixed center crop on real footage (decision 0033). Skipped unless
/// `COURTSIDE_AUTOFOLLOW_EVAL` names a JSON file: `{"out": folder, "moments": [{"name", "path"}]}`.
/// For each moment it times the scan, then exports Vertical at Medium twice, with auto-follow and
/// centered, into `out`, with `results.json` listing the scan time and where each crop was every
/// second. The sources are only read. Nothing is written into the app or the repo; the folder is
/// the caller's to look at and delete.
final class AutoFollowEvaluationTests: XCTestCase {
    private struct Config: Decodable {
        struct Moment: Decodable {
            var name: String
            var path: String
        }

        var out: String
        var moments: [Moment]
        /// Scan only (for timing on another Simulator).
        var scanOnly: Bool?
    }

    private struct Result: Encodable {
        var name: String
        var videoSize: [Double]
        var duration: Double
        var scanSeconds: Double
        var zoom: Double
        var keys: [[Double]]
        var samples: [MotionSample]
        /// Per whole second: [time, center crop's left edge, auto crop's left edge, crop width], 0...1.
        var crops: [[Double]]
        var exportSeconds: [Double]
    }

    func testCompareAutoFollowWithCenterCrop() async throws {
        guard let path = ProcessInfo.processInfo.environment["COURTSIDE_AUTOFOLLOW_EVAL"] else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_AUTOFOLLOW_EVAL to compare auto-follow with the center crop.")
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let out = URL(fileURLWithPath: config.out, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var results: [Result] = []

        for moment in config.moments {
            let source = URL(fileURLWithPath: moment.path)
            let size = try await SlowMoComposer.displaySize(of: source)
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            let started = Date()
            let samples = try await MotionAnalyzer.scan(url: source)
            let scanSeconds = Date().timeIntervalSince(started)
            let zoom = FramingPreset.medium.zoom(videoSize: size)
            let keys = AutoAim.keys(from: samples, zoom: zoom, videoSize: size)
            let motion = AimPath(keys: keys).motion(zoom: zoom, videoSize: size)
            let centered = VerticalFraming(zoom: zoom).clamped(videoSize: size)

            var crops: [[Double]] = []
            var second = 0.0
            while second < duration {
                let center = centered.window(videoSize: size), auto = motion.framing(at: second).window(videoSize: size)
                crops.append([second, Double(center.minX), Double(auto.minX), Double(center.width)])
                second += 1
            }

            var exportSeconds: [Double] = []
            if config.scanOnly != true {
                for (suffix, aim) in [("center", nil), ("auto", AimPath(keys: keys))] as [(String, AimPath?)] {
                    let plan = ExportPlan(source: source, format: .vertical, label: nil, framing: centered, aim: aim)
                    let destination = out.appending(path: "\(moment.name)-\(suffix).mp4")
                    try? FileManager.default.removeItem(at: destination)
                    let exportStarted = Date()
                    try await ClipExtractor.exportForSharing(plan, to: destination) { _ in }
                    exportSeconds.append(Date().timeIntervalSince(exportStarted))
                }
            }
            results.append(Result(
                name: moment.name, videoSize: [size.width, size.height], duration: duration, scanSeconds: scanSeconds,
                zoom: zoom, keys: keys.map { [$0.time, $0.center.x] }, samples: samples, crops: crops,
                exportSeconds: exportSeconds
            ))
            print("AUTOFOLLOW_EVAL \(moment.name) scan \(String(format: "%.2f", scanSeconds)) s, \(keys.count) points")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(results).write(to: out.appending(path: config.scanOnly == true ? "scan-times.json" : "results.json"))
    }
}
