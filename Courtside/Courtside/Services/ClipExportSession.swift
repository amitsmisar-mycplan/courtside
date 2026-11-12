import AVFoundation
import OSLog
import SwiftData
import UIKit

/// Exporting one clip to the camera roll: Photos permission, the render through `ClipExtractor`,
/// saving, and removing the temporary file. The sheet only shows `phase` and sends intents.
@MainActor @Observable
final class ClipExportSession: Identifiable {
    enum Phase: Equatable {
        case choosing
        /// Vertical picked for a landscape clip: zoom and aim points before saving.
        case framing
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
    /// Vertical zoom for a landscape clip (decision 0024): one value for the whole export. Starts at the last zoom used.
    private(set) var zoom = VerticalZoomSettings.lastZoom
    /// Aim points on the source file's timeline, in time order (decision 0028). Always at least one;
    /// a clip without stored points starts with one, centered.
    private(set) var aimKeys: [AimPath.Key]
    /// An aim dragged between points, kept only if the parent adds it as a point.
    private(set) var draft: CGPoint?
    /// Plays the source under the window, for aiming at any moment.
    let preview = ScrubPlayer()

    /// Converts stored points (game-video seconds) to the source's seconds; nil when the session
    /// isn't tied to a stored clip (then points aren't saved).
    let timeline: AimTimeline?

    @ObservationIgnored private let photos: PhotoLibrarySaving
    @ObservationIgnored private let saveAim: (@MainActor (AimTrack?) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// True while a drag has changed a stored point, so it's saved when the drag ends.
    @ObservationIgnored private var aimChanged = false

    init(
        clipID: UUID,
        source: URL,
        label: LabelStep.LabelText? = nil,
        quality: LabelledExportQuality = LabelSettings.labelledQuality,
        aimTrack: AimTrack? = nil,
        timeline: AimTimeline? = nil,
        saveAim: (@MainActor (AimTrack?) -> Void)? = nil,
        photos: PhotoLibrarySaving = PhotoLibraryService()
    ) {
        self.clipID = clipID
        self.source = source
        self.label = label
        self.quality = quality
        self.timeline = timeline
        self.saveAim = saveAim
        self.photos = photos
        let stored = timeline.flatMap { timeline in
            aimTrack?.points.map { AimPath.Key(time: timeline.fileTime($0.time), center: CGPoint(x: $0.x, y: $0.y ?? 0.5)) }
        }
        aimKeys = stored.flatMap { $0.isEmpty ? nil : $0 } ?? [AimPath.Key(time: 0, center: CGPoint(x: 0.5, y: 0.5))]
    }

    /// The session for a stored clip: its aim points are loaded and saved back as they change.
    /// `source` is the clip or its slow-mo version, whichever is showing.
    convenience init(clip: Clip, source: URL, context: ModelContext) {
        let isSlowMo = clip.slowMoURL == source
        self.init(
            clipID: clip.id,
            source: source,
            label: .forExport(game: clip.game),
            aimTrack: clip.aimTrack,
            timeline: AimTimeline(clipStart: clip.startSeconds, slowMo: isSlowMo ? clip.slowMo : nil),
            saveAim: { track in
                clip.aimTrack = track
                try? context.save()
            }
        )
    }

    func plan(for format: ExportFormat) -> ExportPlan {
        ExportPlan(source: source, format: format, label: label, quality: quality,
                   framing: framing(for: format), aim: format == .vertical && canFrame ? AimPath(keys: aimKeys) : nil)
    }

    /// The labelled-copy cache key for `plan`, or nil without a label (nothing is cached then).
    private func cacheKey(for plan: ExportPlan) -> LabelledExportCache.Key? {
        label.map {
            LabelledExportCache.Key(clipID: clipID, source: .init(source), format: plan.format, label: $0, quality: quality,
                                    framing: plan.verticalFraming, aim: plan.aimPath)
        }
    }

    /// The framing a Vertical export of this clip uses; nil for Original and portrait clips.
    private func framing(for format: ExportFormat) -> VerticalFraming? {
        guard format == .vertical, canFrame, let sourceSize else { return nil }
        return VerticalFraming(zoom: zoom, center: aimKeys[0].center).clamped(videoSize: sourceSize)
    }

    // MARK: Vertical zoom and aim

    /// True for a landscape (or wider) clip: Vertical asks for zoom and aim first.
    var canFrame: Bool { sourceSize.map(VerticalFraming.applies(to:)) ?? false }

    /// The slider's top: zooming further would stretch the video more than about 1.5×.
    var maxZoom: Double { sourceSize.map { VerticalFraming.maxZoom(videoSize: $0) } ?? 1 }

    /// True when the slider is held back by the video's resolution and is at that limit.
    var isZoomLimited: Bool { maxZoom < 0.999 && zoom >= maxZoom - 0.005 }

    /// The zoom and aim at the preview's current time: the draft while there is one, otherwise
    /// where the export's window is at that moment (the same `AimMotion` the export uses).
    var framing: VerticalFraming {
        guard let sourceSize else { return VerticalFraming(zoom: zoom, center: draft ?? aimKeys[0].center) }
        if let draft { return VerticalFraming(zoom: zoom, center: draft).clamped(videoSize: sourceSize) }
        return AimPath(keys: aimKeys).motion(zoom: zoom, videoSize: sourceSize).framing(at: preview.currentTime)
            .clamped(videoSize: sourceSize)
    }

    /// The visible part of the clip at the current time, 0...1 from the top-left, for the window
    /// drawn over the video.
    var framingWindow: CGRect {
        guard let sourceSize else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return framing.window(videoSize: sourceSize)
    }

    func setZoom(_ zoom: Double) {
        guard let sourceSize else { return }
        self.zoom = VerticalFraming(zoom: zoom).clamped(videoSize: sourceSize).zoom
    }

    // MARK: Aim points (decision 0028)

    /// How near the playhead must be to a point to be on it.
    static let pointTolerance = 0.2

    /// The point being edited: the one under the playhead, or the only one (it aims the whole clip).
    var selectedPoint: Int? {
        if aimKeys.count == 1 { return 0 }
        let nearest = aimKeys.indices.min { abs(aimKeys[$0].time - preview.currentTime) < abs(aimKeys[$1].time - preview.currentTime) }
        return nearest.flatMap { abs(aimKeys[$0].time - preview.currentTime) <= Self.pointTolerance ? $0 : nil }
    }

    /// True when the playhead is on a point (with one point, only at that point's time).
    var isOnPoint: Bool {
        aimKeys.contains { abs($0.time - preview.currentTime) <= Self.pointTolerance }
    }

    var canAddPoint: Bool { !isOnPoint && aimKeys.count < AimTrack.manualLimit && preview.duration > 0 }
    var isAtPointLimit: Bool { aimKeys.count >= AimTrack.manualLimit }
    var canDeletePoint: Bool { aimKeys.count > 1 && isOnPoint }

    /// Moves the window by a fraction of the clip's width and height. On a point (or with only
    /// one), that point's aim moves; between points the drag makes a draft to add as a point.
    func moveWindow(by delta: CGSize) {
        guard let sourceSize else { return }
        let start = framing.center
        let moved = VerticalFraming(zoom: zoom, center: start).moved(by: delta, videoSize: sourceSize).center
        if draft == nil, let index = selectedPoint {
            if aimKeys.count > 1, abs(preview.currentTime - aimKeys[index].time) > 0.001 {
                // Show the point's own moment while its aim moves.
                preview.seek(to: aimKeys[index].time)
            }
            aimKeys[index].center = moved
            aimChanged = true
        } else {
            draft = moved
        }
    }

    /// The drag ended: a moved point is saved.
    func endMove() {
        if aimChanged { persistAim() }
    }

    /// Adds a point at the current time with the window's aim (the draft, if one was dragged).
    func addPoint() {
        guard canAddPoint else { return }
        let time = preview.currentTime
        aimKeys = AimPath(keys: aimKeys + [AimPath.Key(time: time, center: framing.center)]).keys
        draft = nil
        persistAim()
    }

    func deletePoint() {
        guard canDeletePoint, let index = selectedPoint else { return }
        aimKeys.remove(at: index)
        persistAim()
    }

    /// Tapping a point's mark: go to its moment.
    func selectPoint(_ index: Int) {
        guard aimKeys.indices.contains(index) else { return }
        seek(to: aimKeys[index].time)
    }

    /// Dragging a point's mark along the timeline. It stays between its neighbors, at least
    /// `pointTolerance` from each, so the order never changes.
    func movePoint(_ index: Int, to time: Double) {
        guard aimKeys.indices.contains(index) else { return }
        let low = index > 0 ? aimKeys[index - 1].time + Self.pointTolerance : 0
        let high = index < aimKeys.count - 1 ? aimKeys[index + 1].time - Self.pointTolerance : preview.duration
        guard low <= high else { return }
        aimKeys[index].time = min(max(time, low), high)
        aimChanged = true
        seek(to: aimKeys[index].time)
    }

    /// Scrubbing. A draft not added as a point is dropped.
    func seek(to seconds: Double) {
        draft = nil
        preview.seek(to: seconds)
    }

    func togglePlay() {
        draft = nil
        preview.togglePlay()
    }

    /// Saves the points to the clip: nil for one centered point, the same as no points at all.
    private func persistAim() {
        aimChanged = false
        guard let timeline, let saveAim else { return }
        let isPlain = aimKeys.count == 1 && abs(aimKeys[0].center.x - 0.5) < 0.0005 && abs(aimKeys[0].center.y - 0.5) < 0.0005
        saveAim(isPlain ? nil : AimTrack(points: aimKeys.map {
            AimPoint(time: timeline.gameTime($0.time), x: $0.center.x, y: abs($0.center.y - 0.5) < 0.0005 ? nil : $0.center.y)
        }))
    }

    /// Back to the format list without saving.
    func cancelFraming() {
        if phase == .framing {
            preview.pause()
            draft = nil
            phase = .choosing
        }
    }

    /// True when Original has to be rendered to add the label (slower than saving the clip as it is).
    var addsLabel: Bool { label != nil }

    var isBusy: Bool { phase == .exporting || phase == .saving }

    func load() async {
        sourceSize = try? await SlowMoComposer.displaySize(of: source)
        guard canFrame else { return }
        setZoom(zoom)
        await preview.load(source)
        // One point: the middle of the clip, as before. More: the first point.
        preview.seek(to: aimKeys.count == 1 ? preview.duration / 2 : aimKeys[0].time)
    }

    /// Picking a format in the list: Vertical of a landscape clip goes to zoom and aim first.
    func choose(_ format: ExportFormat) {
        guard !isBusy else { return }
        if format == .vertical, canFrame {
            phase = .framing
        } else {
            export(format)
        }
    }

    func export(_ format: ExportFormat) {
        guard !isBusy else { return }
        if format == .vertical, canFrame {
            // Offered again as the starting zoom next time.
            VerticalZoomSettings.lastZoom = zoom
            preview.pause()
        }
        self.format = format
        progress = 0
        task = Task { await run(format) }
    }

    /// Stops the render; the partial file is removed and nothing is saved.
    func cancel() {
        task?.cancel()
    }

    /// The sheet closed: stops the render and the preview.
    func close() {
        cancel()
        preview.stop()
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
            phase = returnPhase(for: format)
            return
        }

        let plan = plan(for: format)
        if plan.isUnchangedSource {
            // Nothing to render: save the clip itself, no temporary file.
            await save(source, format: format)
            return
        }

        let key = cacheKey(for: plan)
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
            phase = returnPhase(for: format)
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

    /// Where a cancelled render goes back to: the zoom and aim screen, as left, for a framed Vertical.
    private func returnPhase(for format: ExportFormat) -> Phase {
        format == .vertical && canFrame ? .framing : .choosing
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
