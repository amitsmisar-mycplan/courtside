import Foundation
import OSLog

/// Sharing one clip. With the game label on, the labelled Original is rendered first through
/// `ClipExtractor` (same plan and pipeline as Save to Photos), then shared and kept in
/// `LabelledExportCache` for next time (decision 0021). Without a label the clip file itself is
/// shared at once, as before (decision 0020).
@MainActor @Observable
final class ClipShareSession: Identifiable {
    enum Phase: Equatable {
        case idle
        /// Rendering the labelled copy.
        case preparing
        /// The share sheet is open.
        case sharing
        case finished
        case cancelled
        case failed(String)
    }

    private static let log = Logger(subsystem: "Courtside", category: "Share")

    let id = UUID()
    let clipID: UUID
    /// The file being shared: the clip, or its slow-mo version when that's the one showing.
    let source: URL
    /// The game label to burn in, or nil when the setting is Off or the game has no label text.
    let label: LabelStep.LabelText?
    /// Resolution of the labelled copy (decision 0021); no effect without a label.
    let quality: LabelledExportQuality
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    /// When the render started, for the elapsed time on screen.
    private(set) var renderStartedAt: Date?

    @ObservationIgnored private let sharer: FileSharing
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        clipID: UUID,
        source: URL,
        label: LabelStep.LabelText?,
        quality: LabelledExportQuality = LabelSettings.labelledQuality,
        sharer: FileSharing = SystemFileSharing()
    ) {
        self.clipID = clipID
        self.source = source
        self.label = label
        self.quality = quality
        self.sharer = sharer
    }

    /// True when the shared file carries the label (a copy, not the clip itself).
    var addsLabel: Bool { !plan.isUnchangedSource }

    /// True when the labelled copy still has to be made: the progress sheet is shown only then.
    var needsRender: Bool { addsLabel && cacheKey.flatMap(LabelledExportCache.shared.file(for:)) == nil }

    /// Original format only: Share has no format choice.
    var plan: ExportPlan { ExportPlan(source: source, format: .original, label: label, quality: quality) }

    private var cacheKey: LabelledExportCache.Key? {
        label.map { LabelledExportCache.Key(clipID: clipID, source: .init(source), format: .original, label: $0, quality: quality) }
    }

    var isBusy: Bool { phase == .preparing || phase == .sharing }

    func start() {
        guard phase == .idle else { return }
        task = Task { await run() }
    }

    /// Stops the render; the partial file is removed and nothing is shared.
    func cancel() {
        guard phase == .preparing else { return }
        task?.cancel()
    }

    /// Waits for the share to end (tests).
    func finish() async {
        await task?.value
    }

    private func run() async {
        let plan = plan
        guard !plan.isUnchangedSource else {
            // Nothing to render: share the clip itself, no temporary file.
            phase = .sharing
            await sharer.share(source)
            phase = .finished
            return
        }

        if let key = cacheKey, let cached = LabelledExportCache.shared.file(for: key) {
            // Same clip, label and quality as last time: share the copy already made.
            phase = .sharing
            await sharer.share(cached)
            phase = .finished
            return
        }

        phase = .preparing
        renderStartedAt = .now
        let destination = StorageManager.makeExportURL(clipID: clipID, format: .original)
        do {
            try await ClipExtractor.exportForSharing(plan, to: destination) { [weak self] value in
                self?.progress = value
            }
        } catch is CancellationError {
            StorageManager.removeExport(at: destination)
            phase = .cancelled
            return
        } catch {
            StorageManager.removeExport(at: destination)
            Self.log.error("Labelled share render failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else {
            StorageManager.removeExport(at: destination)
            phase = .cancelled
            return
        }
        // Kept for the next share or save of this clip; deleting the clip or relaunching removes it.
        if let key = cacheKey {
            LabelledExportCache.shared.store(destination, for: key)
        }
        phase = .sharing
        await sharer.share(destination)
        phase = .finished
    }
}
