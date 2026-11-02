import Foundation
import OSLog

/// Sharing one clip. With the game label on, the labelled Original is rendered first through
/// `ClipExtractor` (same plan and pipeline as Save to Photos), shared, then removed. Without a
/// label the clip file itself is shared at once, as before (decision 0020).
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
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0

    @ObservationIgnored private let sharer: FileSharing
    @ObservationIgnored private var task: Task<Void, Never>?

    init(clipID: UUID, source: URL, label: LabelStep.LabelText?, sharer: FileSharing = SystemFileSharing()) {
        self.clipID = clipID
        self.source = source
        self.label = label
        self.sharer = sharer
    }

    /// True when a labelled copy has to be made first (slower than sharing the clip as it is).
    var addsLabel: Bool { !plan.isUnchangedSource }

    /// Original format only: Share has no format choice.
    var plan: ExportPlan { ExportPlan(source: source, format: .original, label: label) }

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

        phase = .preparing
        let destination = StorageManager.makeExportURL(clipID: clipID, format: .original)
        // Removed once the share sheet closes, or on cancel/failure; launch cleanup sweeps the rest.
        defer { StorageManager.removeExport(at: destination) }
        do {
            try await ClipExtractor.exportForSharing(plan, to: destination) { [weak self] value in
                self?.progress = value
            }
        } catch is CancellationError {
            phase = .cancelled
            return
        } catch {
            Self.log.error("Labelled share render failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else {
            phase = .cancelled
            return
        }
        phase = .sharing
        await sharer.share(destination)
        phase = .finished
    }
}
