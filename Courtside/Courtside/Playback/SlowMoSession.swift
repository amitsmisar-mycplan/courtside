import AVFoundation
import SwiftData
import UIKit

/// State for the Slow Mo sheet: available speeds, the slow segment, a still poster, instant
/// full-screen preview of the composition (no export, looping), and rendering.
@MainActor @Observable
final class SlowMoSession {
    enum FrameRate: Equatable {
        case loading
        case loaded(Float)
        case failed(String)
    }

    let clip: Clip
    @ObservationIgnored let player = AVPlayer()

    private(set) var frameRate: FrameRate = .loading
    private(set) var speed: SlowMoSpeed
    private(set) var segment: SlowMoSegment
    /// Still at the tap, upright, shown in the sheet instead of a tiny player.
    private(set) var poster: UIImage?
    /// Width ÷ height as the clip appears on screen; nil until loaded.
    private(set) var aspectRatio: CGFloat?
    /// True once a preview item is loaded for the current settings.
    private(set) var hasPreview = false
    private(set) var isBuildingPreview = false
    private(set) var isPreviewPaused = false
    private(set) var isRendering = false
    private(set) var renderProgress: Double = 0
    var errorMessage: String?

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var loopObserver: NSObjectProtocol?

    init(clip: Clip) {
        self.clip = clip
        defer { observeLoop() }
        if let existing = clip.slowMo {
            speed = existing.speed
            segment = existing.segment
        } else {
            speed = .half
            segment = SlowMotion.defaultSegment(markInClip: clip.markInClip, clipDuration: clip.window.duration)
        }
    }

    var clipDuration: Double { clip.window.duration }
    /// Square clips count as landscape.
    var isPortrait: Bool { (aspectRatio ?? 16 / 9) < 1 }
    var markInClip: Double { clip.markInClip }

    var availableSpeeds: [SlowMoSpeed] {
        guard case .loaded(let fps) = frameRate else { return [] }
        return SlowMotion.availableSpeeds(frameRate: fps)
    }

    var limitationMessage: String? {
        guard case .loaded(let fps) = frameRate else { return nil }
        return SlowMotion.limitationMessage(frameRate: fps)
    }

    var canRender: Bool { availableSpeeds.contains(speed) && !isRendering }

    var outputDuration: Double {
        SlowMotion.outputDuration(clipDuration: clipDuration, segment: segment, speed: speed)
    }

    var estimatedFileSize: Int64 {
        SlowMotion.estimatedFileSize(clipFileSize: clip.fileSize, clipDuration: clipDuration, outputDuration: outputDuration)
    }

    /// Safe to call again (the sheet re-appears when the full-screen preview closes).
    func load() async {
        guard frameRate == .loading else { return }
        if let size = try? await SlowMoComposer.displaySize(of: clip.fileURL), size.height > 0 {
            aspectRatio = size.width / size.height
        }
        poster = await ThumbnailGenerator.frame(of: clip.fileURL, at: markInClip, maxDimension: 1080)
        do {
            let fps = try await SlowMoComposer.videoFrameRate(of: clip.fileURL)
            frameRate = .loaded(fps)
            if !availableSpeeds.contains(speed), let fallback = availableSpeeds.first {
                speed = fallback
            }
        } catch {
            frameRate = .failed(error.localizedDescription)
        }
    }

    func select(_ newSpeed: SlowMoSpeed) {
        guard availableSpeeds.contains(newSpeed), newSpeed != speed else { return }
        speed = newSpeed
        clearPreview()
    }

    func setSegment(start: Double, end: Double) {
        let clamped = SlowMotion.clamped(start: start, end: end, clipDuration: clipDuration)
        guard clamped != segment else { return }
        segment = clamped
        clearPreview()
    }

    /// Where preview starts and loops back to: just before the slow part. Before the slow
    /// segment the composition runs at 1×, so clip seconds and composition seconds agree.
    private var previewStart: CMTime {
        CMTime(seconds: max(0, segment.start - 1.5), preferredTimescale: 600)
    }

    /// Plays the composition directly — instant, no export — from just before the slow part.
    /// Reuses the loaded item while the settings are unchanged; it was cleared if they changed.
    func preview() {
        guard !isRendering else { return }
        isPreviewPaused = false
        if hasPreview {
            restartPreview()
            return
        }
        previewTask?.cancel()
        isBuildingPreview = true
        let (url, segment, speed) = (clip.fileURL, segment, speed)
        previewTask = Task { [weak self] in
            do {
                let composition = try await SlowMoComposer.composition(clipURL: url, segment: segment, speed: speed)
                guard let self, !Task.isCancelled else { return }
                self.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                self.hasPreview = true
                self.isBuildingPreview = false
                self.restartPreview()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isBuildingPreview = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func togglePreviewPause() {
        guard hasPreview else { return }
        isPreviewPaused.toggle()
        if isPreviewPaused { player.pause() } else { player.play() }
    }

    /// Leaving full screen: stop playback (and any half-built preview) but keep the item, so
    /// reopening with the same settings is instant. `tearDown()` releases it.
    func closePreview() {
        previewTask?.cancel()
        isBuildingPreview = false
        isPreviewPaused = false
        player.pause()
    }

    private func restartPreview() {
        player.seek(to: previewStart, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.hasPreview, !self.isPreviewPaused else { return }
                self.player.play()
            }
        }
    }

    /// Loops the preview so the slow part can be watched several times.
    private func observeLoop() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                // Other players' items post this too; only loop our own.
                guard let self, let item, item === self.player.currentItem else { return }
                self.restartPreview()
            }
        }
    }

    /// Returns true when the render finished and the clip now has a slow-mo version.
    func render(context: ModelContext) async -> Bool {
        guard canRender else { return false }
        clearPreview()
        isRendering = true
        renderProgress = 0
        defer { isRendering = false }
        do {
            try await ClipExtractor.renderSlowMo(of: clip, segment: segment, speed: speed, context: context) { [weak self] value in
                self?.renderProgress = value
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// The preview item holds the composition's asset; drop it so memory doesn't grow.
    func tearDown() {
        previewTask?.cancel()
        isBuildingPreview = false
        clearPreview()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
    }

    private func clearPreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasPreview = false
        isPreviewPaused = false
    }
}
