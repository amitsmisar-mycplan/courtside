#if DEBUG
import AVFoundation
import CoreImage
import CoreML
import Vision

/// Tap-to-follow feasibility spike (decision 0027). Debug builds only; nothing in the shipped app
/// calls this. Boxes are normalized to the upright picture with the origin at the top left.

/// How the tracker keeps hold of the player.
enum FollowMode: String, CaseIterable, Codable, Sendable {
    /// `VNTrackObjectRequest` alone, seeded once from the tap.
    case trackerOnly
    /// The tracker, re-seeded from Vision's person detector whenever a detected body overlaps the
    /// tracked box (every few frames, or as soon as the tracker's confidence drops).
    case trackerWithResnap

    var title: String {
        switch self {
        case .trackerOnly: "Tracker only"
        case .trackerWithResnap: "Tracker + body re-snap"
        }
    }
}

struct FollowSample: Sendable, Equatable {
    /// Seconds from the start of the tracked range.
    let time: Double
    let box: CGRect
    let confidence: Float
    /// True when this frame's box came from the person detector instead of the tracker.
    let resnapped: Bool
}

struct FollowTrack: Sendable {
    let samples: [FollowSample]
    let mode: FollowMode
    /// Wall-clock time for decoding and tracking the whole clip.
    let processingSeconds: Double
    let videoSeconds: Double
    /// Frames per second actually tracked (frames over 30 fps are skipped).
    let trackedFPS: Double
    let displaySize: CGSize
    /// Times Vision dropped the box (edge of frame, collapsed box) and tracking restarted from the last one.
    var restarts = 0

    var resnaps: Int { samples.filter(\.resnapped).count }
    /// Frames where the tracker reported under 0.3 confidence: usually lost or about to be.
    var lowConfidenceFrames: Int { samples.filter { $0.confidence < 0.3 }.count }
    var minConfidence: Float { samples.map(\.confidence).min() ?? 0 }
    var meanConfidence: Float {
        samples.isEmpty ? 0 : samples.map(\.confidence).reduce(0, +) / Float(samples.count)
    }

    /// The last sample at or before `time` (the first one before tracking reaches it).
    func sample(at time: Double) -> FollowSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count - 1
        if time <= samples[0].time { return samples[0] }
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return samples[low]
    }
}

enum FollowError: LocalizedError {
    case noVideoTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The clip has no video."
        case .readFailed(let detail): "The clip couldn't be read (\(detail))."
        }
    }
}

enum TapToFollowTracker {
    /// Frames over this rate are skipped: tracking every 60 fps frame doubles the work for little gain.
    static let maxTrackedFPS = 30.0
    /// The detector runs on every Nth tracked frame in re-snap mode.
    static let resnapInterval = 5
    /// A detected body must overlap the tracked box at least this much to replace it.
    static let resnapMinimumOverlap: CGFloat = 0.3
    /// Below this the re-snap mode also checks the detector straight away.
    static let lowConfidence: Float = 0.5

    // MARK: First frame

    /// The clip's first frame, upright, and the people Vision finds in it.
    static func firstFrame(of url: URL) async throws -> (image: CGImage, people: [CGRect], displaySize: CGSize) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let image = try await generator.image(at: .zero).image
        let people = try detectPeople(in: VNImageRequestHandler(cgImage: image, orientation: .up))
        let size = try await displaySize(of: asset)
        return (image, people, size)
    }

    /// The person under the tap (the smallest box containing it, so the nearer of two overlapping
    /// players wins), else the nearest one whose centre is within 10 % of the frame, else nil.
    static func snap(tap: CGPoint, to people: [CGRect]) -> CGRect? {
        if let hit = people.filter({ $0.contains(tap) }).min(by: { $0.width * $0.height < $1.width * $1.height }) {
            return hit
        }
        let nearest = people.min { distance($0.followCenter, tap) < distance($1.followCenter, tap) }
        return nearest.flatMap { distance($0.followCenter, tap) <= 0.1 ? $0 : nil }
    }

    /// An upper-body box around a tap that no detected person was near.
    static func fallbackBox(around tap: CGPoint, displaySize: CGSize) -> CGRect {
        // An upper body (like the detector's boxes) is about a tenth of the frame tall in a sideline
        // shot; width from a 1 : 1.5 shape in pixels, converted back to the frame's proportions.
        let height: CGFloat = 0.1
        let width = height / 1.5 * (displaySize.height / max(displaySize.width, 1))
        let rect = CGRect(x: tap.x - width / 2, y: tap.y - height / 2, width: width, height: height)
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: Tracking

    /// Tracks `box` (in the first frame) through the clip.
    static func track(
        url: URL,
        from box: CGRect,
        mode: FollowMode,
        timeRange: CMTimeRange? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FollowTrack {
        let begin = ContinuousClock.now
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw FollowError.noVideoTrack }
        let (transform, assetDuration) = (try await videoTrack.load(.preferredTransform), try await asset.load(.duration))
        let orientation = imageOrientation(for: transform)
        let size = try await displaySize(of: asset)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FollowError.readFailed("no reader output") }
        reader.add(output)
        guard reader.startReading() else { throw FollowError.readFailed(reader.error?.localizedDescription ?? "start") }

        let start = range.start.seconds
        let duration = max(range.duration.seconds, 0.001)
        var handler = VNSequenceRequestHandler()
        var request: VNTrackObjectRequest?
        /// Starts a fresh tracker on `box`. A fresh handler drops the old tracker (Vision caps how many
        /// can be open). Nil when the box is too small or outside the frame to track.
        func restart(from box: CGRect) -> VNTrackObjectRequest? {
            let inside = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !inside.isNull, inside.width > 0.005, inside.height > 0.005 else { return nil }
            handler = VNSequenceRequestHandler()
            let fresh = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect(inside)))
            fresh.trackingLevel = .accurate
            useCPUInSimulator(fresh)
            return fresh
        }
        request = restart(from: box)
        var samples: [FollowSample] = []
        var restarts = 0
        var lastTracked = -Double.infinity
        var frameIndex = 0

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds - start
            // Keep at most 30 frames a second; the small slack keeps every 30 fps frame.
            guard time - lastTracked >= 1 / maxTrackedFPS - 0.004 else { continue }
            lastTracked = time

            let previous = samples.last?.box ?? box
            var tracked: VNDetectedObjectObservation?
            if let current = request {
                // Vision throws when the box reaches the edge or collapses; that counts as lost.
                try? handler.perform([current], on: pixels, orientation: orientation)
                tracked = current.results?.first as? VNDetectedObjectObservation
                if let tracked { current.inputObservation = tracked }
            }
            var sample = tracked.map { FollowSample(time: time, box: topLeftRect($0.boundingBox), confidence: $0.confidence, resnapped: false) }
                ?? FollowSample(time: time, box: previous, confidence: 0, resnapped: false)

            var restarted = false
            if mode == .trackerWithResnap, frameIndex % resnapInterval == 0 || sample.confidence < lowConfidence {
                let people = try detectPeople(in: VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation))
                if let body = bestOverlap(for: sample.box, among: people) {
                    sample = FollowSample(time: time, box: body, confidence: sample.confidence, resnapped: true)
                    request = restart(from: body)
                    restarted = true
                }
            }
            if tracked == nil, !restarted {
                // Pick up again from the last box; if that's gone too, the track stays where it was.
                if request != nil { restarts += 1 }
                request = restart(from: previous)
            }
            samples.append(sample)
            frameIndex += 1
            if frameIndex % 15 == 0 { progress(min(time / duration, 1)) }
        }
        if reader.status == .failed { throw FollowError.readFailed(reader.error?.localizedDescription ?? "read") }

        let elapsed = ContinuousClock.now - begin
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let span = (samples.last?.time ?? 0) - (samples.first?.time ?? 0)
        return FollowTrack(
            samples: samples,
            mode: mode,
            processingSeconds: seconds,
            videoSeconds: duration,
            trackedFPS: samples.count > 1 && span > 0 ? Double(samples.count - 1) / span : 0,
            displaySize: size,
            restarts: restarts
        )
    }

    // MARK: Helpers

    /// The detected body that overlaps `box` most, if it overlaps enough.
    static func bestOverlap(for box: CGRect, among people: [CGRect]) -> CGRect? {
        let best = people.max { overlap(box, $0) < overlap(box, $1) }
        return best.flatMap { overlap(box, $0) >= resnapMinimumOverlap ? $0 : nil }
    }

    /// Intersection over union.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let common = shared.width * shared.height
        return common / (a.width * a.height + b.width * b.height - common)
    }

    /// How Vision should turn a stored frame upright, from the track's rotation.
    static func imageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    /// Vision's boxes have the origin at the bottom left.
    static func topLeftRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    static func visionRect(_ rect: CGRect) -> CGRect { topLeftRect(rect) }

    /// Upper bodies (head and torso). Revision 1: on sideline footage, revision 2's full-body mode
    /// found no one (players are about a fifth of the frame tall), while revision 1 found most of them.
    private static func detectPeople(in handler: VNImageRequestHandler) throws -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.revision = VNDetectHumanRectanglesRequestRevision1
        useCPUInSimulator(request)
        try handler.perform([request])
        return (request.results ?? []).map { topLeftRect($0.boundingBox) }
    }

    /// The Simulator has no Neural Engine or Metal inference context for Vision, so it must use the CPU.
    /// Phones keep Vision's own choice.
    private static func useCPUInSimulator(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let devices = try? request.supportedComputeStageDevices else { return }
        for (stage, choices) in devices {
            if let cpu = choices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    private static func displaySize(of asset: AVURLAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FollowError.noVideoTrack }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rotated = size.applying(transform)
        return CGSize(width: abs(rotated.width), height: abs(rotated.height))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

extension CGRect {
    var followCenter: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
