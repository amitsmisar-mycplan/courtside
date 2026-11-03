import Foundation
import OSLog

/// Exporting one clip to the camera roll: Photos permission, the render through `ClipExtractor`,
/// saving, and removing the temporary file. The sheet only shows `phase` and sends intents.
@MainActor @Observable
final class ClipExportSession: Identifiable {
    enum Phase: Equatable {
        case choosing
        case exporting
        case saving
        case saved(ExportFormat)
        /// Photos access is off; only Settings can turn it back on.
        case denied
        case failed(String)
    }

    private static let log = Logger(subsystem: "Courtside", category: "Export")

    let id = UUID()
    let clipID: UUID
    /// The file being exported: the clip, or its slow-mo version when that's the one showing.
    let source: URL
    private(set) var phase: Phase = .choosing
    private(set) var format: ExportFormat?
    private(set) var progress: Double = 0
    /// The source as shown (rotation applied); nil until loaded.
    private(set) var sourceSize: CGSize?
    /// The game label to burn in, or nil when the setting is Off or the game has no label text.
    let label: LabelStep.LabelText?
    /// Resolution of labelled exports (decision 0021); no effect without a label.
    let quality: LabelledExportQuality
    /// When the current render started, for the elapsed time on screen.
    private(set) var renderStartedAt: Date?

    @ObservationIgnored private let photos: PhotoLibrarySaving
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        clipID: UUID,
        source: URL,
        label: LabelStep.LabelText? = nil,
        quality: LabelledExportQuality = LabelSettings.labelledQuality,
        photos: PhotoLibrarySaving = PhotoLibraryService()
    ) {
        self.clipID = clipID
        self.source = source
        self.label = label
        self.quality = quality
        self.photos = photos
    }

    func plan(for format: ExportFormat) -> ExportPlan {
        ExportPlan(source: source, format: format, label: label, quality: quality)
    }

    /// The labelled-copy cache key for `format`, or nil without a label (nothing is cached then).
    private func cacheKey(for format: ExportFormat) -> LabelledExportCache.Key? {
        label.map { LabelledExportCache.Key(clipID: clipID, source: .init(source), format: format, label: $0, quality: quality) }
    }

    /// True when Original has to be rendered to add the label (slower than saving the clip as it is).
    var addsLabel: Bool { label != nil }

    var isBusy: Bool { phase == .exporting || phase == .saving }

    func load() async {
        sourceSize = try? await SlowMoComposer.displaySize(of: source)
    }

    func export(_ format: ExportFormat) {
        guard !isBusy else { return }
        self.format = format
        progress = 0
        task = Task { await run(format) }
    }

    /// Stops the render; the partial file is removed and nothing is saved.
    func cancel() {
        task?.cancel()
    }

    /// Waits for the current export (tests).
    func finish() async {
        await task?.value
    }

    private func run(_ format: ExportFormat) async {
        // Ask before rendering, so a refusal doesn't cost the parent a wait.
        guard await photos.requestAddAccess() == .granted else {
            phase = .denied
            return
        }
        guard !Task.isCancelled else {
            phase = .choosing
            return
        }

        let plan = plan(for: format)
        if plan.isUnchangedSource {
            // Nothing to render: save the clip itself, no temporary file.
            await save(source, format: format)
            return
        }

        let key = cacheKey(for: format)
        if let key, let cached = LabelledExportCache.shared.file(for: key) {
            // Same clip, label and quality as last time: the copy is already made.
            await save(cached, format: format)
            return
        }

        phase = .exporting
        renderStartedAt = .now
        let destination = StorageManager.makeExportURL(clipID: clipID, format: format)
        do {
            try await ClipExtractor.exportForSharing(plan, to: destination) { [weak self] value in
                self?.progress = value
            }
        } catch is CancellationError {
            StorageManager.removeExport(at: destination)
            phase = .choosing
            return
        } catch {
            StorageManager.removeExport(at: destination)
            Self.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        if let key {
            // Kept for the next save or share of this clip; launch cleanup removes it otherwise.
            LabelledExportCache.shared.store(destination, for: key)
            await save(destination, format: format)
        } else {
            await save(destination, format: format)
            StorageManager.removeExport(at: destination)
        }
    }

    private func save(_ url: URL, format: ExportFormat) async {
        phase = .saving
        do {
            try await photos.saveVideo(at: url)
            phase = .saved(format)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
