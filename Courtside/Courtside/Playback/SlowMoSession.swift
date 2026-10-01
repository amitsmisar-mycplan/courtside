import AVFoundation
import SwiftData

/// State for the Slow Mo sheet: available speeds, the slow segment, instant preview of the
/// composition (no export), and rendering.
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
    /// True once a preview item is loaded for the current settings.
    private(set) var hasPreview = false
    private(set) var isBuildingPreview = false
    private(set) var isRendering = false
    private(set) var renderProgress: Double = 0
    var errorMessage: String?

    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(clip: Clip) {
        self.clip = clip
        if let existing = clip.slowMo {
            speed = existing.speed
            segment = existing.segment
        } else {
            speed = .half
            segment = SlowMotion.defaultSegment(markInClip: clip.markInClip, clipDuration: clip.window.duration)
        }
    }

    var clipDuration: Double { clip.window.duration }
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

    func load() async {
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

    /// Plays the composition directly — instant, no export — starting just before the slow part.
    func preview() {
        previewTask?.cancel()
        isBuildingPreview = true
        let (url, segment, speed) = (clip.fileURL, segment, speed)
        previewTask = Task { [weak self] in
            do {
                let composition = try await SlowMoComposer.composition(clipURL: url, segment: segment, speed: speed)
                guard let self, !Task.isCancelled else { return }
                self.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                await self.player.seek(to: CMTime(seconds: max(0, segment.start - 1.5), preferredTimescale: 600))
                self.player.play()
                self.hasPreview = true
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isBuildingPreview = false
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
        clearPreview()
    }

    private func clearPreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasPreview = false
    }
}
