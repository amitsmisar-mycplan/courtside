import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Auto-follow (decision 0033): the motion analyzer on synthetic frames, turning its samples into
/// aim points, the scan cache, and the export sheet's switch.
final class AutoFollowTests: XCTestCase {
    // MARK: Synthetic frames

    private static let width = 160, height = 90

    /// A fixed, textured background (like a gym: never flat), the same in every frame unless panned.
    private static let background: [UInt8] = {
        var seed: UInt32 = 12345
        return (0..<(width + 40) * height).map { _ in
            seed = seed &* 1_103_515_245 &+ 12345
            return UInt8(60 + Int((seed >> 16) % 140))
        }
    }()

    private struct Block {
        /// Left edge in pixels of the grayscale copy, by frame.
        var x: (Int) -> Int
        var y = 40
        var width = 8
        var height = 16
        var value: UInt8 = 250
    }

    /// `count` frames 0.25 s apart: the background panned left by `pan` pixels a frame, with the
    /// blocks drawn on top in screen positions.
    private func frames(_ count: Int = 24, pan: Int = 0, blocks: [Block]) -> [(time: Double, frame: LumaFrame)] {
        let w = Self.width, h = Self.height
        return (0..<count).map { index in
            var pixels = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    pixels[y * w + x] = Self.background[y * (w + 40) + x + min(index * pan, 39)]
                }
            }
            for block in blocks {
                for y in block.y..<min(block.y + block.height, h) {
                    for x in max(block.x(index), 0)..<min(block.x(index) + block.width, w) {
                        pixels[y * w + x] = block.value
                    }
                }
            }
            return (Double(index) * 0.25, LumaFrame(width: w, height: h, pixels: pixels))
        }
    }

    /// A player running back and forth around `x` (0...1 of the width).
    private func runner(around x: Double, y: Int = 40, size: Int = 8) -> Block {
        let middle = Int(x * Double(Self.width)) - size / 2
        return Block(x: { middle + ($0 % 2 == 0 ? -3 : 3) }, y: y, width: size, height: size * 2)
    }

    private func followed(_ samples: [MotionSample]) -> [Double] { samples.compactMap(\.x) }

    func testFollowsAMoverOnTheLeftAndOnTheRight() {
        for x in [0.25, 0.75] {
            let samples = MotionAnalyzer.samples(frames: frames(blocks: [runner(around: x)]))
            XCTAssertEqual(samples.count, 23)
            let found = followed(samples)
            XCTAssertEqual(found.count, 23, "every frame has motion")
            for value in found { XCTAssertEqual(value, x, accuracy: 0.04) }
        }
    }

    func testTwoMoversTogetherAreFollowedBetweenThem() {
        let samples = MotionAnalyzer.samples(frames: frames(blocks: [runner(around: 0.42), runner(around: 0.58)]))
        for value in followed(samples) { XCTAssertEqual(value, 0.5, accuracy: 0.04) }
    }

    func testALoneMoverDoesNotPullTheMiddleAwayFromTheGroup() {
        // Three players near the left basket, a ref jogging on the far right.
        let group = [runner(around: 0.25), runner(around: 0.32, y: 30), runner(around: 0.38, y: 55)]
        let samples = MotionAnalyzer.samples(frames: frames(blocks: group + [runner(around: 0.85)]))
        for value in followed(samples) { XCTAssertEqual(value, 0.32, accuracy: 0.05) }
    }

    func testMotionInTheEdgeStripsIsIgnored() {
        // Someone walking past at the far left edge, and a fan waving along the top: nothing to follow.
        let edge = Block(x: { $0 % 2 == 0 ? 0 : 3 }, y: 30, width: 5, height: 20)
        let top = Block(x: { 70 + ($0 % 2 == 0 ? 0 : 4) }, y: 0, width: 10, height: 5)
        let samples = MotionAnalyzer.samples(frames: frames(blocks: [edge, top]))
        XCTAssertTrue(followed(samples).isEmpty)
        let keys = AutoAim.keys(from: samples, zoom: FramingPreset.medium.zoom(videoSize: hd), videoSize: hd)
        XCTAssertEqual(keys.map(\.center), [CGPoint(x: 0.5, y: 0.5)], "falls back to the center")
    }

    func testNoMotionFallsBackToTheCenter() {
        let samples = MotionAnalyzer.samples(frames: frames(blocks: []))
        XCTAssertEqual(samples.count, 23)
        XCTAssertTrue(followed(samples).isEmpty)
        let keys = AutoAim.keys(from: samples, zoom: FramingPreset.medium.zoom(videoSize: hd), videoSize: hd)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].center, CGPoint(x: 0.5, y: 0.5))
    }

    func testACameraPanIsUndoneAndAScoreboardFixedToTheScreenIsIgnored() {
        let left = MotionAnalyzer.cameraShift(from: frames(2, pan: 2, blocks: [])[0].frame, to: frames(2, pan: 2, blocks: [])[1].frame)
        XCTAssertEqual(left.dx, -2, "the background slid 2 pixels left")
        XCTAssertEqual(left.dy, 0)
        // The camera pans the whole time; the only real motion is a player on the right. The
        // scoreboard overlay stays put on screen, so against the background it seems to move.
        let scoreboard = Block(x: { _ in 60 }, y: 70, width: 40, height: 8, value: 30)
        let samples = MotionAnalyzer.samples(frames: frames(12, pan: 2, blocks: [scoreboard, runner(around: 0.7, y: 30)]))
        let found = followed(samples)
        XCTAssertGreaterThan(found.count, 8)
        for value in found { XCTAssertEqual(value, 0.7, accuracy: 0.05) }
    }

    // MARK: Samples to aim points

    private let hd = CGSize(width: 1920, height: 1080)

    private func samples(_ xs: [Double?]) -> [MotionSample] {
        xs.enumerated().map { MotionSample(time: Double($0.offset) * 0.25 + 0.25, x: $0.element, y: $0.element == nil ? nil : 0.5) }
    }

    func testAPlayMovingAcrossBecomesAFewEasedPointsWithinTheSpeedCap() {
        // The action goes from the left basket to the right over 12 s.
        let xs = (0..<48).map { 0.15 + 0.7 * Double($0) / 47 }
        let zoom = FramingPreset.medium.zoom(videoSize: hd)
        let keys = AutoAim.keys(from: samples(xs), zoom: zoom, videoSize: hd)
        XCTAssertGreaterThan(keys.count, 1)
        XCTAssertLessThanOrEqual(keys.count, AimTrack.manualLimit, "no more than a parent could set")
        XCTAssertEqual(keys.map(\.time), keys.map(\.time).sorted())
        // Stored where the window really goes, so the points already respect the cap and clamping.
        let motion = AimPath(keys: keys).motion(zoom: zoom, videoSize: hd)
        for (key, reached) in zip(keys, motion.keys) { XCTAssertEqual(key.center.x, reached.center.x, accuracy: 0.0001) }
        XCTAssertLessThan(motion.center(at: 1).x, 0.4, "starts on the left")
        XCTAssertGreaterThan(motion.center(at: 12).x, 0.6, "ends on the right")
        // The action stays inside the window nearly all the time.
        let window = FramingPreset.widthShare(zoom: zoom, videoSize: hd)
        let inside = xs.enumerated().filter { abs(Double(motion.center(at: Double($0.offset) * 0.25 + 0.25).x) - $0.element) < window / 2 }
        XCTAssertGreaterThan(Double(inside.count) / Double(xs.count), 0.9)
    }

    func testABriefOutlierDoesNotPullTheCrop() {
        // Play around 0.3; for half a second someone runs across the far right.
        var xs: [Double?] = Array(repeating: 0.3, count: 40)
        xs[20] = 0.95
        xs[21] = 0.95
        let keys = AutoAim.keys(from: samples(xs), zoom: FramingPreset.medium.zoom(videoSize: hd), videoSize: hd)
        XCTAssertEqual(keys.count, 1, "one aim for the whole clip")
        XCTAssertEqual(keys[0].center.x, 0.3, accuracy: 0.06)
    }

    func testGapsAreFilledAndTheWholeWidthNeedsNoFollowing() {
        let xs: [Double?] = (0..<40).map { $0 % 3 == 0 ? nil : 0.7 }
        let keys = AutoAim.keys(from: samples(xs), zoom: FramingPreset.medium.zoom(videoSize: hd), videoSize: hd)
        XCTAssertEqual(keys.first?.center.x ?? 0, 0.7, accuracy: 0.06)
        XCTAssertEqual(AutoAim.keys(from: samples(xs), zoom: 0, videoSize: hd).map(\.center), [CGPoint(x: 0.5, y: 0.5)],
                       "zoom 0 shows the whole width")
    }

    // MARK: Scan cache

    func testScanCacheIsCheckedAgainstTheFileAndRemovedWithTheClip() throws {
        StorageManager.prepareDirectories()
        let clipID = UUID()
        let source = StorageManager.clipURL(filename: "\(clipID.uuidString).mov")
        try Data(repeating: 1, count: 100).write(to: source)
        defer { StorageManager.removeFile(at: source) }
        let samples = [MotionSample(time: 0.25, x: 0.3, y: 0.5), MotionSample(time: 0.5, x: nil, y: nil)]

        StorageManager.saveMotionScan(samples, forClipID: clipID, source: source)
        let url = StorageManager.motionScanURL(forClipID: clipID, sourceFilename: source.lastPathComponent)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MotionScans")
        XCTAssertTrue(url.path.contains("/Caches/"))
        XCTAssertEqual(StorageManager.loadMotionScan(forClipID: clipID, source: source), samples)

        // A trim rewrites the file under the same name: the old scan no longer applies.
        try Data(repeating: 1, count: 200).write(to: source)
        XCTAssertNil(StorageManager.loadMotionScan(forClipID: clipID, source: source))

        StorageManager.saveMotionScan(samples, forClipID: clipID, source: source)
        let slowMo = StorageManager.clipURL(filename: "\(clipID.uuidString)-slowmo-half.mov")
        StorageManager.saveMotionScan(samples, forClipID: clipID, source: slowMo)
        StorageManager.removeMotionScans(forClipID: clipID)
        XCTAssertFalse(StorageManager.fileExists(at: url))
        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.motionScanURL(forClipID: clipID, sourceFilename: slowMo.lastPathComponent)))
    }

    @MainActor
    func testDeletingAClipOrItsGameRemovesItsScansAndLaunchSweepsStrays() throws {
        StorageManager.prepareDirectories()
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self, Player.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let game = Game(label: "", recordedAt: .now, videoFilename: "auto-follow-test.mov", durationSeconds: 60,
                        source: .imported, videoFileSize: 1)
        context.insert(game)
        func clip() -> Clip {
            let id = UUID()
            let clip = Clip(id: id, filename: "\(id.uuidString).mov", startSeconds: 0, endSeconds: 5, fileSize: 1)
            context.insert(clip)
            clip.game = game
            return clip
        }
        let first = clip(), second = clip()
        try context.save()
        let scan = [MotionSample(time: 0.25, x: 0.4, y: 0.5)]
        for clip in [first, second] {
            StorageManager.saveMotionScan(scan, forClipID: clip.id, source: StorageManager.clipURL(for: clip))
        }
        func scanExists(_ clip: Clip) -> Bool {
            StorageManager.fileExists(at: StorageManager.motionScanURL(forClipID: clip.id, sourceFilename: clip.filename))
        }
        XCTAssertTrue(scanExists(first))

        StorageManager.deleteClip(first, in: context)
        XCTAssertFalse(scanExists(first))
        XCTAssertTrue(scanExists(second))

        // A scan left behind by a clip that's gone (say, the app quit mid-delete) is swept on launch.
        let stray = UUID()
        StorageManager.saveMotionScan(scan, forClipID: stray, source: StorageManager.clipURL(filename: "\(stray.uuidString).mov"))
        StorageManager.performLaunchCleanup(in: context)
        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.motionScanURL(forClipID: stray, sourceFilename: "\(stray.uuidString).mov")))
        XCTAssertTrue(scanExists(second), "a live clip's scan stays")

        let secondID = second.id, secondFile = second.filename
        StorageManager.deleteGame(game, in: context)
        XCTAssertFalse(StorageManager.fileExists(at: StorageManager.motionScanURL(forClipID: secondID, sourceFilename: secondFile)))
    }

    // MARK: The Vertical screen

    private struct NoPhotos: PhotoLibrarySaving {
        func requestAddAccess() async -> PhotoAccess { .granted }
        func saveVideo(at url: URL) async throws {}
    }

    /// A 2-second 1280×720 clip of a bright player running about three quarters of the way
    /// across a textured, still background.
    private func makeClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autofollow-\(UUID().uuidString).mov")
        let width = 1280, height = 720
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        // The background in 8-pixel cells of different grays, so it has texture, like a gym.
        var background = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // Hashed per cell, so no shift of the picture lines it up with itself.
                let value = UInt8(70 + (((x / 8) &* 73_856_093 ^ (y / 8) &* 19_349_663) & 0x7fff_ffff) % 9 * 15)
                let i = (y * width + x) * 4
                background[i] = value
                background[i + 1] = value
                background[i + 2] = value
            }
        }
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            // Runs right 4 pixels a frame and starts over each second.
            let playerX = 900 + frame % 30 * 4
            for y in 0..<height {
                let row = base + y * rowBytes
                background.withUnsafeBufferPointer { row.update(from: $0.baseAddress! + y * width * 4, count: width * 4) }
                if y >= 330, y < 430 {
                    for x in playerX..<(playerX + 40) {
                        row[x * 4] = 255
                        row[x * 4 + 1] = 255
                        row[x * 4 + 2] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @MainActor
    func testOnByDefaultFollowsTheMotionAndHandEditsMakeThePointsManual() async throws {
        let url = try await makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        var saved: [AimTrack?] = []
        let session = ClipExportSession(clipID: UUID(), source: url, aimTrack: nil, timeline: AimTimeline(clipStart: 100),
                                        saveAim: { saved.append($0) }, followsByDefault: true, photos: NoPhotos())
        defer { StorageManager.removeMotionScans(forClipID: session.clipID) }
        await session.load()
        XCTAssertTrue(session.isFindingAction, "a clip with no aim starts scanning")
        XCTAssertFalse(session.mayCutOffSides, "no warning while it's finding the action")
        await session.finishAutoFollow()

        XCTAssertEqual(session.autoFollow, .on)
        XCTAssertTrue(session.isAutoFollowing)
        XCTAssertGreaterThan(session.framing.center.x, 0.6, "aimed toward the player on the right")
        XCTAssertFalse(session.mayCutOffSides)
        XCTAssertEqual(saved.last??.origin, .automatic, "stored as auto points, in the same track")
        XCTAssertNotNil(StorageManager.loadMotionScan(forClipID: session.clipID, source: url), "the scan is cached")

        // Wide / Medium / Tight still sets how much shows; the auto points follow at the new zoom.
        session.selectPreset(.wide)
        XCTAssertEqual(session.selectedPreset, .wide)
        XCTAssertTrue(session.isAutoFollowing)

        // Dragging a point: the auto points stay, now as manual ones.
        let before = session.aimKeys
        session.seek(to: before[0].time)
        session.moveWindow(by: CGSize(width: -0.05, height: 0))
        session.endMove()
        XCTAssertFalse(session.isAutoFollowing)
        XCTAssertEqual(session.autoFollow, .off)
        XCTAssertEqual(session.aimKeys.count, before.count, "the points are kept to edit")
        XCTAssertEqual(saved.last??.origin, .manual)

        // Turning it back on uses the cached scan; turning it off goes back to one centered aim,
        // stored as a choice so it doesn't come back on next time.
        session.setAutoFollow(true)
        XCTAssertTrue(session.isAutoFollowing, "no rescan needed")
        session.setAutoFollow(false)
        XCTAssertEqual(session.aimKeys.map(\.center), [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(saved.last??.origin, .manual)
        XCTAssertEqual(saved.last??.points.count, 1)
        XCTAssertTrue(session.mayCutOffSides, "back to today's one centered aim")
        session.close()

        let reopened = ClipExportSession(clipID: session.clipID, source: url, aimTrack: saved.last ?? nil,
                                         timeline: AimTimeline(clipStart: 100), saveAim: { _ in }, followsByDefault: true,
                                         photos: NoPhotos())
        await reopened.load()
        XCTAssertEqual(reopened.autoFollow, .off, "turned off for this clip, so it stays off")
        reopened.close()
    }

    @MainActor
    func testAddingAPointWhileItScansStopsTheScanAndKeepsItManual() async throws {
        let url = try await makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ClipExportSession(clipID: UUID(), source: url, timeline: AimTimeline(clipStart: 0), saveAim: { _ in },
                                        followsByDefault: true, photos: NoPhotos())
        defer { StorageManager.removeMotionScans(forClipID: session.clipID) }
        await session.load()
        XCTAssertTrue(session.isFindingAction)
        session.seek(to: 0.5)
        session.addPoint()
        await session.finishAutoFollow()
        XCTAssertFalse(session.isAutoFollowing)
        XCTAssertEqual(session.autoFollow, .off)
        XCTAssertEqual(session.aimKeys.count, 2)
        session.close()
    }

    @MainActor
    func testOffByDefaultLeavesTheClipCenteredUntilTurnedOn() async throws {
        let url = try await makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ClipExportSession(clipID: UUID(), source: url, photos: NoPhotos())
        await session.load()
        XCTAssertEqual(session.autoFollow, .off)
        XCTAssertEqual(session.aimKeys.map(\.center), [CGPoint(x: 0.5, y: 0.5)])
        session.setAutoFollow(true)
        await session.finishAutoFollow()
        XCTAssertTrue(session.isAutoFollowing)
        XCTAssertGreaterThan(session.framing.center.x, 0.6)
        session.close()
    }

    func testTheQueuedScanMatchesADirectScan() async throws {
        // The scan reads only the clip file, so recorded and imported games are analysed the same way.
        let url = try await makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try await MotionScanQueue.shared.scan(url) { _ in }
        let second = try await MotionAnalyzer.scan(url: url)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.compactMap(\.x).count, first.count / 2)
    }
}
