import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// "Clip quality" (decision 0023): 1080p clips and trims from 4K game videos, never scaled up,
/// Full quality as before, and clips already made left alone when the setting changes.
@MainActor
final class ClipQualityTests: XCTestCase {
    private static let uhd = CGSize(width: 3840, height: 2160)
    private static let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    private var files: [URL] = []
    private var savedQuality: Any?

    override func setUp() async throws {
        StorageManager.prepareDirectories()
        savedQuality = UserDefaults.standard.object(forKey: ClipSettings.qualityKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedQuality, forKey: ClipSettings.qualityKey)
        files.forEach(StorageManager.removeFile(at:))
    }

    private func setQuality(_ quality: ClipQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: ClipSettings.qualityKey)
    }

    private func makeSource(size: CGSize, transform: CGAffineTransform = .identity, seconds: Int = 6) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "quality-\(UUID().uuidString).mov")
        files.append(url)
        try await TestMedia.makeVideo(at: url, seconds: seconds, fps: 10, transform: transform, size: size, withTone: true)
        return url
    }

    /// Cuts 1–5 s of `source` at `quality`; returns the clip's shown size and length.
    private func cut(_ source: URL, quality: ClipQuality) async throws -> (size: CGSize, duration: Double) {
        let clip = FileManager.default.temporaryDirectory.appending(path: "quality-clip-\(UUID().uuidString).mov")
        files.append(clip)
        try await ClipExtractor.export(source: source, window: ClipWindow(start: 1, end: 5), to: clip, quality: quality) { _ in }
        return try await describe(clip)
    }

    private func describe(_ url: URL) async throws -> (size: CGSize, duration: Double) {
        (try await SlowMoComposer.displaySize(of: url), try await AVURLAsset(url: url).load(.duration).seconds)
    }

    // MARK: The setting

    func testDefaultIs1080p() {
        UserDefaults.standard.removeObject(forKey: ClipSettings.qualityKey)
        XCTAssertEqual(ClipSettings.quality, .hd1080)
        setQuality(.full)
        XCTAssertEqual(ClipSettings.quality, .full)
        XCTAssertEqual(ClipQuality.hd1080.title, "1080p (faster)")
        XCTAssertEqual(ClipQuality.full.title, "Full quality")
    }

    // MARK: Sizes

    func test4KLandscapeGivesA1080pClipOfTheRightLength() async throws {
        let clip = try await cut(try await makeSource(size: Self.uhd), quality: .hd1080)
        XCTAssertEqual(clip.size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(clip.duration, 4, accuracy: 0.15)
    }

    func test4KPortraitStoredRotatedStaysPortrait() async throws {
        let clip = try await cut(try await makeSource(size: Self.uhd, transform: Self.quarterTurn), quality: .hd1080)
        XCTAssertEqual(clip.size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(clip.duration, 4, accuracy: 0.15)
    }

    func test4KPortraitStoredUprightStaysPortrait() async throws {
        let clip = try await cut(try await makeSource(size: CGSize(width: 2160, height: 3840)), quality: .hd1080)
        XCTAssertEqual(clip.size, CGSize(width: 1080, height: 1920))
    }

    func test1080pAndSmallerSourcesAreNotScaledUp() async throws {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 320, height: 180)] {
            let clip = try await cut(try await makeSource(size: size), quality: .hd1080)
            XCTAssertEqual(clip.size, size, "\(size) kept as it is")
            XCTAssertEqual(clip.duration, 4, accuracy: 0.15)
        }
    }

    func testFullQualityKeeps4K() async throws {
        let clip = try await cut(try await makeSource(size: Self.uhd), quality: .full)
        XCTAssertEqual(clip.size, Self.uhd, "today's output")
        XCTAssertEqual(clip.duration, 4, accuracy: 0.15)
    }

    // MARK: Through the app's paths

    /// A 4K game, one tap at 5 s, and the clip made for it through `ClipExtractor` at the current setting.
    private func makeGameWithClip(in context: ModelContext) async throws -> (Game, Clip) {
        let id = UUID()
        let filename = StorageManager.makeGameVideoFilename(id: id, fileExtension: "mov")
        let videoURL = StorageManager.gameVideoURL(filename: filename)
        try await TestMedia.makeVideo(at: videoURL, seconds: 12, fps: 10, size: Self.uhd, withTone: false)
        files.append(videoURL)
        let game = Game(id: id, label: "", recordedAt: .now, videoFilename: filename, durationSeconds: 12,
                        source: .imported, videoFileSize: StorageManager.fileSize(at: videoURL))
        context.insert(game)
        let mark = Mark(offsetSeconds: 5)
        context.insert(mark)
        mark.game = game
        mark.part = game.firstPart
        try context.save()

        let extractor = ClipExtractor()
        XCTAssertTrue(extractor.start(game: game, context: context))
        while extractor.phase == .running { try await Task.sleep(for: .milliseconds(50)) }
        let clip = try XCTUnwrap(game.clips.first)
        files += [clip.fileURL, StorageManager.thumbnailURL(forClipID: clip.id)]
        return (game, clip)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    func testNewClipsFollowTheSetting() async throws {
        setQuality(.hd1080)
        let (_, clip) = try await makeGameWithClip(in: try makeContext())
        let made = try await describe(clip.fileURL)
        XCTAssertEqual(made.size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(made.duration, clip.window.duration, accuracy: 0.15)

        setQuality(.full)
        let (_, full) = try await makeGameWithClip(in: try makeContext())
        let fullSize = try await SlowMoComposer.displaySize(of: full.fileURL)
        XCTAssertEqual(fullSize, Self.uhd)
    }

    func testTrimFollowsTheSetting() async throws {
        let context = try makeContext()
        setQuality(.full)
        let (game, clip) = try await makeGameWithClip(in: context)
        let firstSize = try await SlowMoComposer.displaySize(of: clip.fileURL)
        XCTAssertEqual(firstSize, Self.uhd)

        setQuality(.hd1080)
        let bounds = ClipWindow.trimBounds(mark: clip.markTime, gameDuration: game.firstPart.durationSeconds, current: clip.window)
        let wider = clip.window.trimming(.end, to: clip.endSeconds + 1, within: bounds)
        try await ClipExtractor.trim(clip, to: wider, context: context) { _ in }
        let trimmed = try await describe(clip.fileURL)
        XCTAssertEqual(trimmed.size, CGSize(width: 1920, height: 1080), "re-cut at the new setting")
        XCTAssertEqual(trimmed.duration, wider.duration, accuracy: 0.15)
        XCTAssertEqual(clip.fileSize, StorageManager.fileSize(at: clip.fileURL))

        setQuality(.full)
        try await ClipExtractor.trim(clip, to: clip.window.trimming(.start, to: clip.startSeconds - 1, within: bounds), context: context) { _ in }
        let back = try await SlowMoComposer.displaySize(of: clip.fileURL)
        XCTAssertEqual(back, Self.uhd)
    }

    func testExistingClipIsUntouchedWhenTheSettingChanges() async throws {
        let context = try makeContext()
        setQuality(.full)
        let (game, clip) = try await makeGameWithClip(in: context)
        let attributes = try FileManager.default.attributesOfItem(atPath: clip.fileURL.path)
        let window = clip.window

        setQuality(.hd1080)
        // Making clips again (nothing pending) must not remake this one.
        let extractor = ClipExtractor()
        XCTAssertTrue(extractor.start(game: game, context: context))
        while extractor.phase == .running { try await Task.sleep(for: .milliseconds(50)) }

        let after = try FileManager.default.attributesOfItem(atPath: clip.fileURL.path)
        XCTAssertEqual(after[.size] as? Int64, attributes[.size] as? Int64)
        XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        let size = try await SlowMoComposer.displaySize(of: clip.fileURL)
        XCTAssertEqual(size, Self.uhd, "still the 4K clip it was")
        XCTAssertEqual(clip.window, window)
        XCTAssertEqual(game.clips.count, 1)
    }

    // MARK: Labelled exports

    func testLabelledExportOfA1080pClipIsNotRescaled() async throws {
        let clip = try await makeSource(size: CGSize(width: 1920, height: 1080), seconds: 4)
        let label = LabelStep.LabelText(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: .now)
        let plan = ExportPlan(source: clip, format: .original, label: label, quality: .hd1080)
        let output = try await ExportComposer.build(plan)
        XCTAssertEqual(output.videoComposition?.renderSize, CGSize(width: 1920, height: 1080), "canvas is the clip's own size")

        let exported = FileManager.default.temporaryDirectory.appending(path: "quality-label-\(UUID().uuidString).mov")
        files.append(exported)
        try await ClipExtractor.exportForSharing(plan, to: exported) { _ in }
        let size = try await SlowMoComposer.displaySize(of: exported)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
    }
}
