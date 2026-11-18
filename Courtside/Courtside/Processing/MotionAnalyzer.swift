import AVFoundation
import CoreGraphics
import Foundation

/// A small grayscale copy of one video frame, as shown (rotation applied), for motion analysis.
struct LumaFrame: Sendable {
    let width: Int
    let height: Int
    /// Row by row from the top-left, 0 black ... 255 white.
    var pixels: [UInt8]

    /// Half the width and height, each pixel the average of four.
    func halved() -> LumaFrame {
        let w = width / 2, h = height / 2
        var result = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * width + 2 * x
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + width]) + Int(pixels[i + width + 1])
                result[y * w + x] = UInt8(sum / 4)
            }
        }
        return LumaFrame(width: w, height: h, pixels: result)
    }
}

/// Where the motion was at one moment of a file (decision 0033).
struct MotionSample: Codable, Hashable, Sendable {
    /// Seconds into the analysed file.
    var time: Double
    /// Middle of the motion, 0...1 from the top-left; nil when there was nothing reliable to follow
    /// (no one moving, or the whole picture moved because the camera did).
    var x: Double?
    var y: Double?
}

/// A saved scan of one clip file (decision 0033), checked against the file's size so a trimmed or
/// re-rendered file under the same name is scanned again.
struct MotionScanFile: Codable, Sendable {
    static let currentVersion = 1
    var version = MotionScanFile.currentVersion
    var sourceFileSize: Int64
    var samples: [MotionSample]
}

/// Auto-follow's motion analysis (decision 0033): frame differencing on a tiny grayscale copy of
/// the video, about 4 frames a second. No models, no recognition: it only finds where pixels
/// change. Tripod footage is the target, so the background is still and motion is the players.
enum MotionAnalyzer {
    static let samplesPerSecond = 4.0
    /// Width of the grayscale copy; the height follows the video's shape.
    static let gridWidth = 160
    /// Left and right strips left out (benches, fans walking past the camera).
    static let sideShare = 0.06
    /// Top and bottom strips left out (stands, people in front of the camera).
    static let topShare = 0.08
    static let bottomShare = 0.08
    /// A pixel moved when its brightness changed by more than this.
    static let changeThreshold = 18
    /// Fewer moving pixels than this share of the picture: nothing to follow.
    static let minimumMovingShare = 0.002
    /// More than this share moving at once: the camera moved, not the players.
    static let shakeShare = 0.35
    /// The motion is looked for in the densest stretch this wide, so a lone mover elsewhere (a ref,
    /// a sub at the scorer's table) doesn't pull the middle away from the group.
    static let clusterShare = 0.4
    /// A spot in the top or bottom quarter that moves in more than this share of the frames is an
    /// overlay or a sign (a running game clock), not play.
    static let persistentShare = 0.6

    // MARK: Pure analysis

    /// Samples pooled on each side when looking for the densest motion: about 1.25 s in all, so a
    /// player crossing for a moment doesn't move the middle on their own.
    static let poolRadius = 2

    /// One sample per frame after the first: where the motion between it and the frame before is,
    /// pooled with the frames around it.
    static func samples(frames: [(time: Double, frame: LumaFrame)]) -> [MotionSample] {
        guard frames.count >= 2 else { return [] }
        let width = frames[0].frame.width, height = frames[0].frame.height
        let maps = (1..<frames.count).map { changes(from: frames[$0 - 1].frame, to: frames[$0].frame) }
        let ignored = persistentSpots(in: maps, width: width, height: height)
        // Each frame's motion across the width, as shares of its own total, so a frame where much
        // moved doesn't outweigh its neighbors; nil when it had nothing reliable.
        let profiles = maps.map { columnProfile(of: $0, width: width, height: height, ignoring: ignored) }
        return maps.indices.map { index in
            var pooled = Array(repeating: 0.0, count: width)
            var count = 0
            for other in max(0, index - poolRadius)...min(maps.count - 1, index + poolRadius) {
                guard let profile = profiles[other] else { continue }
                for x in 0..<width { pooled[x] += profile[x] }
                count += 1
            }
            let time = frames[index + 1].time
            guard profiles[index] != nil || count >= 2, count > 0, let stretch = densestStretch(pooled) else {
                return MotionSample(time: time, x: nil, y: nil)
            }
            let x = centroid(pooled, in: stretch) / Double(width)
            let y = verticalCenter(of: maps[index], width: width, height: height, columns: stretch, ignoring: ignored)
            return MotionSample(time: time, x: x, y: y ?? 0.5)
        }
    }

    /// True for each pixel that moved, inside the area that counts. When the camera panned, the
    /// frames are lined up on the background first, so only what moved against it counts; and a
    /// pixel must also have changed on screen, so an overlay fixed to the screen (a scoreboard)
    /// doesn't look like motion when the background slides under it.
    static func changes(from previous: LumaFrame, to current: LumaFrame) -> [Bool] {
        guard previous.width == current.width, previous.height == current.height else {
            return Array(repeating: false, count: current.pixels.count)
        }
        let width = current.width, height = current.height
        let shift = cameraShift(from: previous, to: current)
        var map = Array(repeating: false, count: current.pixels.count)
        let area = countedArea(width: width, height: height)
        for y in area.rows {
            for x in area.columns {
                let i = y * width + x
                let value = Int(current.pixels[i])
                guard abs(value - Int(previous.pixels[i])) > changeThreshold else { continue }
                // Where this pixel was before the pan; it moved only if nothing within a pixel of
                // there matches it (that also absorbs the pan being off by part of a pixel).
                let px = x - shift.dx, py = y - shift.dy
                guard px >= 1, px < width - 1, py >= 1, py < height - 1 else { continue }
                var closest = Int.max
                for oy in -1...1 {
                    for ox in -1...1 {
                        closest = min(closest, abs(value - Int(previous.pixels[(py + oy) * width + px + ox])))
                    }
                }
                map[i] = closest > changeThreshold
            }
        }
        return map
    }

    /// How far the picture slid between the frames, in pixels of the grayscale copy: content at
    /// (x, y) before is at (x + dx, y + dy) now. Zero unless a shift lines the frames up clearly
    /// better, so players moving over a plain floor aren't mistaken for a pan.
    static func cameraShift(from previous: LumaFrame, to current: LumaFrame) -> (dx: Int, dy: Int) {
        let half = (previous.halved(), current.halved())
        var best = (dx: 0, dy: 0), bestCost = difference(half.0, half.1, dx: 0, dy: 0)
        let still = bestCost
        for dy in -4...4 {
            for dx in -10...10 where dx != 0 || dy != 0 {
                let cost = difference(half.0, half.1, dx: dx, dy: dy)
                if cost < bestCost { (best, bestCost) = ((dx, dy), cost) }
            }
        }
        guard bestCost < still * 0.8 else { return (0, 0) }
        // Refine at full size around the coarse answer.
        var fine = (dx: best.dx * 2, dy: best.dy * 2)
        var fineCost = difference(previous, current, dx: fine.dx, dy: fine.dy)
        let center = fine
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let cost = difference(previous, current, dx: center.dx + dx, dy: center.dy + dy)
                if cost < fineCost { (fine, fineCost) = ((center.dx + dx, center.dy + dy), cost) }
            }
        }
        return fine
    }

    /// Average brightness difference where the frames overlap with `current` shifted back by (dx, dy).
    private static func difference(_ previous: LumaFrame, _ current: LumaFrame, dx: Int, dy: Int) -> Double {
        let width = current.width, height = current.height
        let xs = max(0, dx)..<min(width, width + dx), ys = max(0, dy)..<min(height, height + dy)
        guard !xs.isEmpty, !ys.isEmpty else { return .infinity }
        var total = 0, count = 0
        for y in ys {
            let row = y * width, before = (y - dy) * width - dx
            for x in xs {
                total += abs(Int(current.pixels[row + x]) - Int(previous.pixels[before + x]))
                count += 1
            }
        }
        return Double(total) / Double(count)
    }

    /// The columns and rows inside the left-out strips.
    static func countedArea(width: Int, height: Int) -> (columns: Range<Int>, rows: Range<Int>) {
        let left = Int((Double(width) * sideShare).rounded())
        let top = Int((Double(height) * topShare).rounded())
        let bottom = Int((Double(height) * bottomShare).rounded())
        return (left..<max(width - left, left), top..<max(height - bottom, top))
    }

    /// Pixels in the top and bottom quarters that change in most frames: a clock or a screen.
    static func persistentSpots(in maps: [[Bool]], width: Int, height: Int) -> Set<Int> {
        guard maps.count >= 8 else { return [] }
        var spots = Set<Int>()
        let quarter = height / 4
        for y in 0..<height where y < quarter || y >= height - quarter {
            for x in 0..<width {
                let i = y * width + x
                let moving = maps.reduce(0) { $0 + ($1[i] ? 1 : 0) }
                if Double(moving) > Double(maps.count) * persistentShare { spots.insert(i) }
            }
        }
        return spots
    }

    /// The middle of the densest group of moving pixels in one frame, 0...1; nil when too few
    /// moved or too many.
    static func center(of map: [Bool], width: Int, height: Int, ignoring ignored: Set<Int> = []) -> CGPoint? {
        guard let profile = columnProfile(of: map, width: width, height: height, ignoring: ignored),
              let stretch = densestStretch(profile) else { return nil }
        let y = verticalCenter(of: map, width: width, height: height, columns: stretch, ignoring: ignored) ?? 0.5
        return CGPoint(x: centroid(profile, in: stretch) / Double(width), y: y)
    }

    /// Moving pixels per column as shares of the frame's total; nil when too few moved (nothing to
    /// follow) or too many (the camera moved more than lining up the frames could undo).
    static func columnProfile(of map: [Bool], width: Int, height: Int, ignoring ignored: Set<Int>) -> [Double]? {
        let area = countedArea(width: width, height: height)
        let counted = area.columns.count * area.rows.count
        guard counted > 0 else { return nil }
        var columns = Array(repeating: 0.0, count: width)
        var moving = 0
        for y in area.rows {
            for x in area.columns {
                let i = y * width + x
                if map[i], !ignored.contains(i) {
                    columns[x] += 1
                    moving += 1
                }
            }
        }
        let share = Double(moving) / Double(counted)
        guard share >= minimumMovingShare, share <= shakeShare else { return nil }
        return columns.map { $0 / Double(moving) }
    }

    /// The columns of the `clusterShare`-wide stretch holding the most motion; nil without any.
    static func densestStretch(_ columns: [Double]) -> Range<Int>? {
        let width = columns.count
        let span = max(1, Int((Double(width) * clusterShare).rounded()))
        var best = 0.0, bestStart = 0, running = 0.0
        for x in 0..<width {
            running += columns[x]
            if x >= span { running -= columns[x - span] }
            if running > best + 1e-9 {
                best = running
                bestStart = max(0, x - span + 1)
            }
        }
        return best > 0 ? bestStart..<min(bestStart + span, width) : nil
    }

    /// The weighted middle of `columns` inside `stretch`, in columns.
    static func centroid(_ columns: [Double], in stretch: Range<Int>) -> Double {
        var sum = 0.0, total = 0.0
        for x in stretch {
            sum += (Double(x) + 0.5) * columns[x]
            total += columns[x]
        }
        return total > 0 ? sum / total : Double(stretch.lowerBound + stretch.upperBound) / 2
    }

    /// The middle height of the motion inside `columns`, 0...1; nil when none moved there.
    static func verticalCenter(of map: [Bool], width: Int, height: Int, columns: Range<Int>, ignoring ignored: Set<Int>) -> Double? {
        let area = countedArea(width: width, height: height)
        var sum = 0.0, total = 0.0
        for y in area.rows {
            for x in columns where area.columns.contains(x) {
                let i = y * width + x
                guard map[i], !ignored.contains(i) else { continue }
                sum += Double(y) + 0.5
                total += 1
            }
        }
        return total > 0 ? sum / total / Double(height) : nil
    }

    // MARK: Reading a file

    enum ScanError: Error {
        case noVideo
    }

    /// Reads `url` once, keeping about `samplesPerSecond` frames as small grayscale copies, and
    /// returns where the motion is in each. Stops with `CancellationError` when its task is cancelled.
    static func scan(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [MotionSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ScanError.noVideo }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let width = gridWidth
        let height = max(1, Int((Double(width) * Double(abs(shown.height)) / Double(max(abs(shown.width), 1))).rounded()))
        var sampler: Sampler?
        var frames: [(time: Double, frame: LumaFrame)] = []
        var next = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time + 0.001 >= next, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            if sampler == nil {
                sampler = Sampler(width: width, height: height, natural: natural, transform: transform, shown: shown)
            }
            if let frame = sampler?.frame(from: pixels) {
                frames.append((time, frame))
            }
            next = time + 1 / samplesPerSecond
            if duration > 0 { progress(min(time / duration, 1)) }
        }
        if reader.status == .failed { throw reader.error ?? ScanError.noVideo }
        try Task.checkCancellation()
        return samples(frames: frames)
    }

    /// Picks, for each cell of the grayscale copy, four luma pixels of the decoded frame, with the
    /// video's rotation applied, so the copy is the picture as it's shown.
    private struct Sampler {
        let width: Int
        let height: Int
        /// Four (x, y) positions in the natural frame per cell.
        let points: [(Int, Int)]

        init(width: Int, height: Int, natural: CGSize, transform: CGAffineTransform, shown: CGRect) {
            self.width = width
            self.height = height
            let inverse = transform.inverted()
            var points: [(Int, Int)] = []
            points.reserveCapacity(width * height * 4)
            for gy in 0..<height {
                for gx in 0..<width {
                    for (dx, dy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                        let shownPoint = CGPoint(x: shown.minX + (Double(gx) + dx) / Double(width) * shown.width,
                                                 y: shown.minY + (Double(gy) + dy) / Double(height) * shown.height)
                        let p = shownPoint.applying(inverse)
                        points.append((min(max(Int(p.x), 0), Int(natural.width) - 1), min(max(Int(p.y), 0), Int(natural.height) - 1)))
                    }
                }
            }
            self.points = points
        }

        func frame(from buffer: CVPixelBuffer) -> LumaFrame? {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planar = CVPixelBufferIsPlanar(buffer)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
            else { return nil }
            let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
            let bufferWidth = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
            let bufferHeight = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            var pixels = [UInt8](repeating: 0, count: width * height)
            for cell in 0..<(width * height) {
                var sum = 0
                for k in 0..<4 {
                    let (x, y) = points[cell * 4 + k]
                    sum += Int(luma[min(y, bufferHeight - 1) * rowBytes + min(x, bufferWidth - 1)])
                }
                pixels[cell] = UInt8(sum / 4)
            }
            return LumaFrame(width: width, height: height, pixels: pixels)
        }
    }
}

/// Runs one motion scan at a time, off the main thread (decision 0033). Cancelling the caller's task
/// cancels its scan; a scan waiting its turn starts only after the one before has stopped.
actor MotionScanQueue {
    static let shared = MotionScanQueue()
    private var tail: Task<Void, Never>?

    func scan(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [MotionSample] {
        let previous = tail
        // The parent is watching the progress, so it runs as their request, not as background work.
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            try Task.checkCancellation()
            return try await MotionAnalyzer.scan(url: url, progress: progress)
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
