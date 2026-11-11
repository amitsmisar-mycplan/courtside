import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Courtside

/// Times the tap-to-follow tracker (decision 0027) on real footage. Skipped unless
/// `COURTSIDE_TIMING_SOURCES` names one or more videos (pass `TEST_RUNNER_COURTSIDE_TIMING_SOURCES`
/// to `xcodebuild`). From each source, 13 s clips are cut at a few points into a temporary folder
/// (1080p, plus one at full quality); the "tap" is the largest person Vision finds in the first
/// frame. Each clip is tracked in both modes; results print as `FOLLOW|` lines. Sources are read
/// only and everything made is removed. With `COURTSIDE_FOLLOW_SHEETS` set to a folder outside the
/// repo, a contact sheet (one frame a second, box drawn) is written there per run for review.
final class TapToFollowTimingTests: XCTestCase {
    func testTrackingTimesOnRealFootage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let list = environment["COURTSIDE_TIMING_SOURCES"] ?? ""
        let sources = list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_TIMING_SOURCES to time tap-to-follow on real footage.")
        }
        let sheets = environment["COURTSIDE_FOLLOW_SHEETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let work = FileManager.default.temporaryDirectory.appending(path: "follow-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for source in sources {
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            let points: [(Double, ClipQuality)] = [(0.3, .hd1080), (0.5, .hd1080), (0.7, .hd1080), (0.5, .full)]
            for (fraction, quality) in points {
                let start = max(0, duration * fraction - 6.5)
                let clip = work.appending(path: "clip.mov")
                try await ClipExtractor.export(source: source, window: ClipWindow(start: start, end: start + 13), to: clip, quality: quality) { _ in }
                let frame = try await TapToFollowTracker.firstFrame(of: clip)
                let name = "\(source.deletingPathExtension().lastPathComponent)@\(Int(start))s-\(quality == .full ? "full" : "1080p")"
                guard let player = frame.people.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
                    print("FOLLOW|\(name)|no people found in the first frame")
                    try? FileManager.default.removeItem(at: clip)
                    continue
                }
                for mode in FollowMode.allCases {
                    let track = try await TapToFollowTracker.track(url: clip, from: player, mode: mode)
                    print(String(
                        format: "FOLLOW|%@|%dx%d|%@|people %d|%.1f s for %.1f s (%.2fx)|%d frames @ %.0f fps|resnaps %d|unsure %d|min %.2f|mean %.2f",
                        name, Int(track.displaySize.width), Int(track.displaySize.height), mode.title, frame.people.count,
                        track.processingSeconds, track.videoSeconds, track.processingSeconds / track.videoSeconds,
                        track.samples.count, track.trackedFPS, track.resnaps, track.lowConfidenceFrames, track.minConfidence, track.meanConfidence
                    ))
                    if let sheets {
                        try await writeSheet(clip: clip, track: track, to: sheets.appending(path: "\(name)-\(mode.rawValue).jpg"))
                    }
                }
                try? FileManager.default.removeItem(at: clip)
            }
        }
    }

    /// One frame a second with the tracked box, in a grid. For eyeballing failure patterns only.
    private func writeSheet(clip: URL, track: FollowTrack, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = stride(from: 0.0, to: track.videoSeconds, by: 1.0).map { $0 }
        var tiles: [(CGImage, FollowSample?)] = []
        for time in times {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            tiles.append((image, track.sample(at: time)))
        }
        guard let first = tiles.first?.0 else { return }
        let tile = CGSize(width: first.width, height: first.height)
        let columns = 4, rows = (tiles.count + columns - 1) / columns
        let context = CGContext(data: nil, width: Int(tile.width) * columns, height: Int(tile.height) * rows, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let height = CGFloat(context.height)
        for (index, (image, sample)) in tiles.enumerated() {
            let origin = CGPoint(x: CGFloat(index % columns) * tile.width, y: height - CGFloat(index / columns + 1) * tile.height)
            context.draw(image, in: CGRect(origin: origin, size: tile))
            if let sample {
                let box = CGRect(x: origin.x + sample.box.minX * tile.width, y: origin.y + (1 - sample.box.maxY) * tile.height,
                                 width: sample.box.width * tile.width, height: sample.box.height * tile.height)
                context.setStrokeColor(sample.confidence >= 0.5 ? CGColor(red: 0, green: 1, blue: 0, alpha: 1) : CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.setLineWidth(3)
                context.stroke(box)
            }
        }
        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, sheet, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
