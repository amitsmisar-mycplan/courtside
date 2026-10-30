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

    @ObservationIgnored private let photos: PhotoLibrarySaving
    @ObservationIgnored private var task: Task<Void, Never>?

    init(clipID: UUID, source: URL, photos: PhotoLibrarySaving = PhotoLibraryService()) {
        self.clipID = clipID
        self.source = source
        self.photos = photos
    }

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

        let plan = ExportPlan(source: source, format: format)
        if plan.isUnchangedSource {
            // Nothing to render: save the clip itself, no temporary file.
            await save(source, format: format)
            return
        }

        phase = .exporting
        let destination = StorageManager.makeExportURL(clipID: clipID, format: format)
        defer { StorageManager.removeExport(at: destination) }
        do {
            try await ClipExtractor.exportForSharing(plan, to: destination) { [weak self] value in
                self?.progress = value
            }
        } catch is CancellationError {
            phase = .choosing
            return
        } catch {
            Self.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        await save(destination, format: format)
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
