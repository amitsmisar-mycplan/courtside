import AVFoundation
import OSLog
import SwiftData
import UIKit

enum ClipExportError: LocalizedError {
    case couldNotCreateSession
    case failed(underlying: Error?)
    case sourceUnavailable
    case cannotNudge
    case slowMoSegmentsNotContiguous

    var errorDescription: String? {
        switch self {
        case .couldNotCreateSession, .failed:
            "The clip couldn't be exported."
        case .sourceUnavailable:
            "The full game video has been deleted, so this clip can't be adjusted."
        case .cannotNudge:
            "The clip can't be adjusted any further in that direction."
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
        case cancelled
    }

    nonisolated private static let log = Logger(subsystem: "Courtside", category: "Extraction")

    private(set) var phase: Phase = .idle
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failed = 0
    /// Progress of the clip currently exporting, 0...1.
    private(set) var currentProgress: Double = 0

    @ObservationIgnored private var runTask: Task<Void, Never>?

    var overallProgress: Double {
        guard total > 0 else { return 1 }
        return min(1, (Double(completed + failed) + currentProgress) / Double(total))
    }

    /// 1-based index of the clip being exported.
    var currentIndex: Int { min(total, completed + failed + 1) }

    func start(game: Game, context: ModelContext) {
        guard phase != .running else { return }
        let marks = game.pendingMarks
        total = marks.count
        completed = 0
        failed = 0
        currentProgress = 0
        phase = .running
        runTask = Task { await run(game: game, marks: marks, context: context) }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func run(game: Game, marks: [Mark], context: ModelContext) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClipExtraction") { [weak self] in
            self?.cancel()
        }
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }

        let source = StorageManager.gameVideoURL(for: game)
        let preRoll = ClipSettings.preRoll
        let postRoll = ClipSettings.postRoll

        for mark in marks {
            if Task.isCancelled { break }
            currentProgress = 0
            let window = ClipWindow.around(
                mark: mark.offsetSeconds,
                preRoll: preRoll,
                postRoll: postRoll,
                gameDuration: game.durationSeconds
            )
            guard window.isExtractable else {
                Self.log.error("Skipping mark at \(mark.offsetSeconds)s: window too short")
                mark.isExtracted = true
                failed += 1
                continue
            }

            let clipID = UUID()
            let filename = StorageManager.makeClipFilename(id: clipID)
            let destination = StorageManager.clipURL(filename: filename)
            do {
                try await Self.export(source: source, window: window, to: destination) { [weak self] value in
                    self?.currentProgress = value
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
                mark.isExtracted = true
                game.processedAt = .now
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
        phase = Task.isCancelled ? .cancelled : .finished
    }

    /// Re-exports `clip` with its edges shifted, replacing its file in place.
    static func nudge(_ clip: Clip, startBy startDelta: Double, endBy endDelta: Double, context: ModelContext) async throws {
        guard let game = clip.game, game.isVideoAvailable else { throw ClipExportError.sourceUnavailable }
        guard let window = clip.window.nudged(startBy: startDelta, endBy: endDelta, gameDuration: game.durationSeconds) else {
            throw ClipExportError.cannotNudge
        }
        let destination = StorageManager.clipURL(for: clip)
        try await export(source: StorageManager.gameVideoURL(for: game), window: window, to: destination) { _ in }
        StorageManager.removeThumbnail(forClipID: clip.id)
        // The slow-motion render was cut from the old clip, so it's stale now.
        StorageManager.removeSlowMoFile(of: clip)
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
    /// keyframes, which lands clips a second or two away from the tap.
    nonisolated static func export(
        source: URL,
        window: ClipWindow,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let range = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            end: CMTime(seconds: window.end, preferredTimescale: 600)
        )
        try await run(asset: AVURLAsset(url: source), timeRange: range, to: destination, progress: progress)
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

    private nonisolated static func run(
        asset: AVAsset,
        timeRange: CMTimeRange?,
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

        let poller = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                session.cancelExport()
            }
            try StorageManager.moveReplacing(partialURL, to: destination)
        } catch {
            StorageManager.removeFile(at: partialURL)
            throw error
        }
        await progress(1)
    }
}
