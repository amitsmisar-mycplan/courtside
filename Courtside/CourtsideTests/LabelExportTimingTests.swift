import AVFoundation
import CoreImage
import XCTest
@testable import Courtside

/// Times labelled exports on real footage (decision 0021). Skipped unless `COURTSIDE_TIMING_SOURCES`
/// names one or more videos (comma-separated; pass it to `xcodebuild` as
/// `TEST_RUNNER_COURTSIDE_TIMING_SOURCES`). Sources are read only: a 13 s clip is cut from each into
/// a temporary folder, timed, and everything it created is removed. Results print as `TIMING|` lines.
@MainActor
final class LabelExportTimingTests: XCTestCase {
    private static let clipLength = 13.0
    private let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)
    private var work: URL!

    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appending(path: "timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        StorageManager.prepareDirectories()
        LabelledExportCache.shared.removeAll()
    }

    override func tearDown() async throws {
        LabelledExportCache.shared.removeAll()
        try? FileManager.default.removeItem(at: work)
    }

    func testLabelledExportTimes() async throws {
        let list = ProcessInfo.processInfo.environment["COURTSIDE_TIMING_SOURCES"] ?? ""
        let sources = list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_TIMING_SOURCES to time labelled exports on real footage.")
        }
        for source in sources {
            try await time(source)
        }
    }

    private func time(_ source: URL) async throws {
        let name = source.lastPathComponent
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        // A clip as the app cuts one: 13 s from the middle, full quality.
        let start = max(0, duration / 2 - Self.clipLength / 2)
        let clip = work.appending(path: "clip-\(UUID().uuidString).mov")
        let cut = try await measure { try await ClipExtractor.export(source: source, window: ClipWindow(start: start, end: start + Self.clipLength), to: clip) { _ in } }
        await report(name, "cut 13 s clip (no label)", cut, file: clip)

        // Where the time goes. No frames drawn: AVFoundation can copy the clip's frames as they are.
        let plain = work.appending(path: "plain.mov")
        let copy = try await measure { try await ClipExtractor.export(source: clip, window: ClipWindow(start: 0, end: Self.clipLength), to: plain) { _ in } }
        await report(name, "no label, no frames drawn", copy, file: plain)
        // Every frame through the composition, nothing drawn: the decode + encode a label forces.
        for cap in [nil, ExportPlan.cappedLongSide] {
            let plan = ExportPlan(source: clip, format: .original, frameSteps: [NothingDrawn()], maxLongSide: cap)
            let seconds = try await measure { try await ClipExtractor.exportForSharing(plan, to: plain) { _ in } }
            await report(name, "every frame re-made, nothing drawn, \(cap == nil ? "Full quality" : "1080p")", seconds, file: plain)
        }
        try? FileManager.default.removeItem(at: plain)

        for quality in [LabelledExportQuality.full, .hd1080] {
            LabelledExportCache.shared.removeAll()
            let clipID = UUID()
            let photos = TimingPhotos()
            let save = ClipExportSession(clipID: clipID, source: clip, label: label, quality: quality, photos: photos)
            let saveTime = try await measure {
                save.export(.original)
                await save.finish()
            }
            XCTAssertEqual(save.phase, .saved(.original), "\(name) \(quality)")
            await report(name, "Save to Photos, labelled, \(quality.title)", saveTime, detail: photos.detail)

            // Same clip, label and quality: the cached copy.
            let sharer = TimingSharer()
            let again = ClipShareSession(clipID: clipID, source: clip, label: label, quality: quality, sharer: sharer)
            XCTAssertFalse(again.needsRender)
            let againTime = try await measure {
                again.start()
                await again.finish()
            }
            XCTAssertEqual(again.phase, .finished)
            await report(name, "Share after saving (cached), \(quality.title)", againTime, detail: sharer.detail)

            // A first share, nothing cached.
            LabelledExportCache.shared.removeAll()
            let coldSharer = TimingSharer()
            let share = ClipShareSession(clipID: UUID(), source: clip, label: label, quality: quality, sharer: coldSharer)
            let shareTime = try await measure {
                share.start()
                await share.finish()
            }
            XCTAssertEqual(share.phase, .finished)
            await report(name, "Share, labelled, \(quality.title)", shareTime, detail: coldSharer.detail)
        }
        LabelledExportCache.shared.removeAll()
        try? FileManager.default.removeItem(at: clip)
    }

    private func measure(_ body: () async throws -> Void) async throws -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func report(_ source: String, _ what: String, _ seconds: Double, file: URL? = nil, detail: String = "") async {
        var detail = detail
        if let file { detail = await Self.describe(file) }
        print("TIMING|\(source)|\(what)|\(String(format: "%.1f", seconds))|\(detail)")
    }

    nonisolated static func describe(_ url: URL) async -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let size = (try? await SlowMoComposer.displaySize(of: url)) ?? .zero
        return "\(Int(size.width))×\(Int(size.height)), \(String(format: "%.1f", Double(bytes) / 1_000_000)) MB"
    }
}

/// A frame step that draws nothing, so the composition cost can be timed without the label.
private struct NothingDrawn: ExportFrameStep {
    func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage { image }
}

private final class TimingPhotos: PhotoLibrarySaving, @unchecked Sendable {
    var detail = ""
    func requestAddAccess() async -> PhotoAccess { .granted }
    func saveVideo(at url: URL) async throws { detail = await LabelExportTimingTests.describe(url) }
}

@MainActor
private final class TimingSharer: FileSharing {
    var detail = ""
    func share(_ url: URL) async { detail = await LabelExportTimingTests.describe(url) }
}
