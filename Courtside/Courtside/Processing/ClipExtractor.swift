import AVFoundation
import OSLog
import SwiftData
import UIKit

enum ClipExportError: LocalizedError {
    case couldNotCreateSession
    case failed(underlying: Error?)
    case sourceUnavailable
    case cannotTrim
    case slowMoSegmentsNotContiguous

    var errorDescription: String? {
        switch self {
        case .couldNotCreateSession, .failed:
            "The clip couldn't be exported."
        case .sourceUnavailable:
            "The full game video has been deleted, so this clip can't be adjusted."
        case .cannotTrim:
            "That range can't be used for this clip."
        case .slowMoSegmentsNotContiguous:
            "The slow-motion version couldn't be put together. Try a slightly different slow section."
        }
    }
}

/// The only thing that runs an export. Exports run serially: concurrent exports cause
/// memory pressure and thermal spikes.
@MainActor @Observable
final class ClipExtractor {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        /// Stopped by the parent.
        case cancelled
        /// Stopped because iOS ended the app's background time. The missing clips are made
        /// when the app is back on screen (decision 0017).
        case interrupted
    }

    nonisolated private static let log = Logger(subsystem: "Courtside", category: "Extraction")
    /// One batch at a time across the whole app: exports are serial, never parallel.
    private static var isBusy = false

    private(set) var phase: Phase = .idle
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failed = 0
    /// Progress of the clip currently exporting, 0...1.
    private(set) var currentProgress: Double = 0

    @ObservationIgnored private let backgroundTime: BackgroundTimeGranting
    @ObservationIgnored private let unfinished: UnfinishedClips
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var gameID: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier?
    @ObservationIgnored private var backgroundTimeExpired = false
    /// Where the clip being exported is written until it's complete.
    @ObservationIgnored private var currentPartial: URL?

    init(backgroundTime: BackgroundTimeGranting = SystemBackgroundTime(), unfinished: UnfinishedClips = UnfinishedClips()) {
        self.backgroundTime = backgroundTime
        self.unfinished = unfinished
    }

    var overallProgress: Double {
        guard total > 0 else { return 1 }
        return min(1, (Double(completed + failed) + currentProgress) / Double(total))
    }

    /// 1-based index of the clip being exported.
    var currentIndex: Int { min(total, completed + failed + 1) }

    /// Makes clips for the game's pending marks, in every part whose video is there, in part order
    /// then time. Returns false if a batch is already running anywhere in the app.
    @discardableResult
    func start(game: Game, context: ModelContext) -> Bool {
        guard phase != .running, !Self.isBusy else { return false }
        Self.isBusy = true
        let marks = game.extractableMarks
        total = marks.count
        completed = 0
        failed = 0
        currentProgress = 0
        backgroundTimeExpired = false
        phase = .running
        // Listed until the batch ends on its own or the parent stops it, so a run the system cuts
        // short (or a crash) is picked up again at the next launch.
        gameID = game.id
        unfinished.add(game.id)
        backgroundTask = backgroundTime.begin(name: "ClipExtraction") { [weak self] in
            self?.backgroundTimeRanOut()
        }
        runTask = Task { await run(game: game, marks: marks, context: context) }
        return true
    }

    /// The parent stopped: the remaining marks wait on the game page and aren't resumed automatically.
    func cancel() {
        switch phase {
        case .running:
            runTask?.cancel()
        case .interrupted:
            if let gameID { unfinished.remove(gameID) }
            phase = .cancelled
        default:
            break
        }
    }

    /// iOS is about to suspend the app. Cancel the current export and delete its partial file now,
    /// and give the background time back at once: iOS kills apps that hold it past expiry.
    /// Finished clips, marks, and the game video are untouched.
    private func backgroundTimeRanOut() {
        Self.log.info("Background time ran out; stopping clip-making to resume later")
        if phase == .running {
            backgroundTimeExpired = true
            runTask?.cancel()
            if let currentPartial { StorageManager.removeFile(at: currentPartial) }
        }
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard let task = backgroundTask else { return }
        backgroundTask = nil
        backgroundTime.end(task)
    }

    private func run(game: Game, marks: [Mark], context: ModelContext) async {
        defer {
            endBackgroundTime()
            Self.isBusy = false
        }

        let preRoll = ClipSettings.preRoll
        let postRoll = ClipSettings.postRoll
        // Read once, so one batch never mixes qualities.
        let quality = ClipSettings.quality

        for mark in marks {
            if Task.isCancelled { break }
            currentProgress = 0
            guard let part = mark.resolvedPart, part.isVideoAvailable else {
                // Its video went while waiting; the mark stays pending, as for a deleted game video.
                failed += 1
                continue
            }
            // Already has its clip (e.g. made just before the app was closed): never make a second one.
            // Tap times are only compared within the same part (decision 0022).
            if game.clips.contains(where: { clip in
                clip.id == mark.id
                    || (clip.resolvedPart === part && clip.markSeconds.map { abs($0 - mark.offsetSeconds) < 0.001 } == true)
            }) {
                mark.isExtracted = true
                try? context.save()
                completed += 1
                continue
            }
            // Clamped to this part's video: a clip never crosses into another part.
            let window = ClipWindow.around(
                mark: mark.offsetSeconds,
                preRoll: preRoll,
                postRoll: postRoll,
                gameDuration: part.durationSeconds
            )
            let source = StorageManager.videoURL(for: part)
            guard window.isExtractable else {
                Self.log.error("Skipping mark at \(mark.offsetSeconds)s: window too short")
                mark.isExtracted = true
                failed += 1
                continue
            }

            // Named after its mark, so a clip whose file was finished but never recorded (the app
            // was closed between the two) is found and adopted instead of exported again.
            let clipID = mark.id
            let filename = StorageManager.makeClipFilename(id: clipID)
            let destination = StorageManager.clipURL(filename: filename)
            do {
                if StorageManager.fileExists(at: destination) {
                    Self.log.info("Adopting finished clip file for mark at \(mark.offsetSeconds)s")
                } else {
                    currentPartial = StorageManager.partialURL(for: destination)
                    defer { currentPartial = nil }
                    try await Self.export(source: source, window: window, to: destination, quality: quality) { [weak self] value in
                        self?.currentProgress = value
                    }
                }
                let clip = Clip(
                    id: clipID,
                    filename: filename,
                    startSeconds: window.start,
                    endSeconds: window.end,
                    fileSize: StorageManager.fileSize(at: destination),
                    markSeconds: mark.offsetSeconds
                )
                context.insert(clip)
                clip.game = game
                clip.part = part
                mark.isExtracted = true
                part.processedAt = .now
                try? context.save()
                completed += 1
            } catch is CancellationError {
                break
            } catch {
                // One bad export must not abort the batch; the mark stays pending for a retry.
                Self.log.error("Export failed for mark at \(mark.offsetSeconds)s: \(error.localizedDescription)")
                failed += 1
            }
        }

        currentProgress = 0
        game.isProcessed = game.marks.allSatisfy(\.isExtracted)
        try? context.save()
        if backgroundTimeExpired {
            phase = .interrupted
        } else {
            unfinished.remove(game.id)
            phase = Task.isCancelled ? .cancelled : .finished
        }
    }

    /// Re-cuts `clip` from its part's video to `window`, replacing its file in place (same
    /// filename; the new file is written aside first, so a failed export keeps the old clip).
    /// The window must lie inside that part: a clip never crosses into another (decision 0022).
    /// Encoded at the current "Clip quality" setting (decision 0023).
    static func trim(
        _ clip: Clip,
        to window: ClipWindow,
        quality: ClipQuality = ClipSettings.quality,
        context: ModelContext,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let part = clip.resolvedPart, part.isVideoAvailable,
              StorageManager.fileExists(at: StorageManager.videoURL(for: part))
        else { throw ClipExportError.sourceUnavailable }
        guard window.duration >= ClipWindow.trimMinimumDuration - 0.001,
              window.start >= 0, window.end <= part.durationSeconds + 0.001
        else { throw ClipExportError.cannotTrim }
        // Fixed before the edges move, so the tap stays on the same game moment.
        let mark = clip.markTime
        let destination = StorageManager.clipURL(for: clip)
        try await export(source: StorageManager.videoURL(for: part), window: window, to: destination, quality: quality, progress: progress)
        StorageManager.removeThumbnail(forClipID: clip.id)
        // The slow-motion render was cut from the old clip, so it's stale now.
        StorageManager.removeSlowMoFile(of: clip)
        clip.markSeconds = mark
        clip.startSeconds = window.start
        clip.endSeconds = window.end
        clip.fileSize = StorageManager.fileSize(at: destination)
        try context.save()
    }

    /// Renders (or re-renders) the clip's slow-motion version. The new file is written before
    /// the old one is removed, so a failed render leaves the previous version intact.
    static func renderSlowMo(
        of clip: Clip,
        segment: SlowMoSegment,
        speed: SlowMoSpeed,
        context: ModelContext,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let filename = StorageManager.makeSlowMoFilename(clipID: clip.id, speed: speed)
        let destination = StorageManager.clipURL(filename: filename)
        let previous = clip.slowMoURL
        try await exportSlowMo(clipURL: clip.fileURL, segment: segment, speed: speed, to: destination, progress: progress)
        if let previous, previous != destination {
            StorageManager.removeFile(at: previous)
        }
        clip.slowMoFilename = filename
        clip.slowMoSpeed = speed.rawValue
        clip.slowMoStartSeconds = segment.start
        clip.slowMoEndSeconds = segment.end
        clip.slowMoFileSize = StorageManager.fileSize(at: destination)
        try context.save()
    }

    /// Frame-accurate re-encode of `window`. Not passthrough: passthrough only cuts on
    /// keyframes, which lands clips a second or two away from the tap. At `.hd1080`, a source
    /// larger than 1920 on the long side uses the HEVC 1080p preset (decision 0023); anything
    /// smaller, and `.full`, keeps HEVC Highest Quality at the source's own size.
    nonisolated static func export(
        source: URL,
        window: ClipWindow,
        to destination: URL,
        quality: ClipQuality = .full,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let range = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            end: CMTime(seconds: window.end, preferredTimescale: 600)
        )
        let asset = AVURLAsset(url: source)
        let scalesDown = quality == .hd1080 ? (try? await isLargerThan1080p(asset)) == true : false
        let preset = scalesDown ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality
        try await run(asset: asset, timeRange: range, to: destination, preset: preset, progress: progress)
    }

    /// True when the video's long side is over 1920: only then does 1080p scale it (never up).
    private nonisolated static func isLargerThan1080p(_ asset: AVAsset) async throws -> Bool {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let size = try await track.load(.naturalSize)
        return max(abs(size.width), abs(size.height)) > ExportPlan.cappedLongSide
    }

    /// Renders the slow-motion composition of a clip. Re-encoded, never passthrough.
    nonisolated static func exportSlowMo(
        clipURL: URL,
        segment: SlowMoSegment,
        speed: SlowMoSpeed,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let composition = try await SlowMoComposer.composition(clipURL: clipURL, segment: segment, speed: speed)
        do {
            try await run(asset: composition, timeRange: nil, to: destination, progress: progress)
        } catch ClipExportError.failed(let underlying) {
            // Some HEVC encoders reject time-scaled compositions (seen with real phone footage in the
            // Simulator). A slow-mo clip in H.264 beats no slow-mo clip, so retry once (decision 0009).
            log.error("HEVC slow-mo export failed, retrying with H.264: \(String(describing: underlying))")
            await progress(0)
            try await run(asset: composition, timeRange: nil, to: destination, preset: AVAssetExportPresetHighestQuality, progress: progress)
        }
    }

    /// Renders a clip for posting (vertical layout, label, later watermark and end card) to `destination`.
    /// Same preset as every other export, except a plan capped at 1080p, which uses the HEVC 1080p
    /// preset (labelled exports only, decision 0021). Cancelling removes the partial file.
    nonisolated static func exportForSharing(
        _ plan: ExportPlan,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let output = try await ExportComposer.build(plan)
        let preset = plan.maxLongSide != nil ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality
        try await run(
            asset: output.asset, timeRange: nil, videoComposition: output.videoComposition,
            to: destination, preset: preset, progress: progress
        )
    }

    private nonisolated static func run(
        asset: AVAsset,
        timeRange: CMTimeRange?,
        videoComposition: AVVideoComposition? = nil,
        to destination: URL,
        preset: String = AVAssetExportPresetHEVCHighestQuality,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let created = AVAssetExportSession(asset: asset, presetName: preset)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw ClipExportError.couldNotCreateSession
        }
        // Read for progress and cancelled from other threads; both are safe on AVAssetExportSession.
        nonisolated(unsafe) let session = created

        let partialURL = StorageManager.partialURL(for: destination)
        StorageManager.removeFile(at: partialURL)
        session.outputURL = partialURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        if let timeRange {
            session.timeRange = timeRange
        }
        if let videoComposition {
            session.videoComposition = videoComposition
        }

        let poller = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }

        do {
            // A cancel can land before the export starts (iOS ending background time between two
            // clips). Cancelling a session that hasn't started and then starting it raises an
            // exception that kills the app, so the two are ordered through `start`.
            let start = ExportStart()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard start.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    defer { start.didBegin() }
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            let code = (session.error as NSError?)?.code
                            if code == AVError.Code.compositionTrackSegmentsNotContiguous.rawValue {
                                continuation.resume(throwing: ClipExportError.slowMoSegmentsNotContiguous)
                            } else {
                                continuation.resume(throwing: ClipExportError.failed(underlying: session.error))
                            }
                        }
                    }
                }
            } onCancel: {
                if start.cancel() { session.cancelExport() }
            }
            try StorageManager.moveReplacing(partialURL, to: destination)
        } catch {
            StorageManager.removeFile(at: partialURL)
            throw error
        }
        await progress(1)
    }
}

/// Orders "start the export" against "cancel it", which arrive on different threads: a cancel
/// before the start means it never starts; a cancel after it cancels the running export.
private final class ExportStart: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var hasStarted = false

    /// False when already cancelled. Otherwise holds the lock until `didBegin()`, so a cancel
    /// arriving meanwhile waits until `exportAsynchronously` has been called.
    func begin() -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return false
        }
        return true
    }

    func didBegin() {
        hasStarted = true
        lock.unlock()
    }

    /// True when the export is running and must be cancelled.
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        return hasStarted
    }
}
