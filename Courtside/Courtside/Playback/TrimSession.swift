import AVFoundation
import SwiftData
import UIKit

/// State for trimming one clip: plays the chosen range of the full game video, moves the edges,
/// and saves through `ClipExtractor`. Dragging only seeks the preview; nothing exports until Save.
@MainActor @Observable
final class TrimSession {
    static let filmstripFrames = 8

    let clip: Clip
    @ObservationIgnored let player = AVPlayer()

    /// Why trimming is off, or nil when the full game video is there to trim from.
    let unavailableReason: String?
    /// The tap, in game-video seconds.
    let mark: Double
    /// How far the edges may go.
    let bounds: ClipWindow
    /// The clip as saved, to compare against.
    let original: ClipWindow
    private(set) var window: ClipWindow
    private(set) var filmstrip: [UIImage] = []
    /// Width ÷ height of the game video as shown; nil until loaded.
    private(set) var aspectRatio: CGFloat?
    private(set) var isPlaying = false
    private(set) var isSaving = false
    private(set) var saveProgress: Double = 0
    var errorMessage: String?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var isDragging = false

    init(clip: Clip) {
        self.clip = clip
        let game = clip.game
        let duration = game?.durationSeconds ?? clip.endSeconds
        mark = clip.markTime
        original = clip.window
        window = clip.window
        bounds = ClipWindow.trimBounds(mark: clip.markTime, gameDuration: duration, current: clip.window)

        if let game, game.isVideoAvailable, StorageManager.fileExists(at: StorageManager.gameVideoURL(for: game)) {
            unavailableReason = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: StorageManager.gameVideoURL(for: game)))
            observeTime()
        } else {
            unavailableReason = "The full game video has been deleted, so this clip can't be trimmed. Trimming re-cuts the clip from the full video."
        }
    }

    var canTrim: Bool { unavailableReason == nil }
    var hasChanges: Bool { window != original }
    var defaultWindow: ClipWindow { ClipWindow.defaultTrim(mark: mark, gameDuration: clip.game?.durationSeconds ?? bounds.end) }
    var isDefault: Bool { abs(window.start - defaultWindow.start) < 0.05 && abs(window.end - defaultWindow.end) < 0.05 }
    var canSave: Bool { canTrim && hasChanges && !isSaving }

    // MARK: Preview

    func load() async {
        guard canTrim, let game = clip.game else { return }
        let url = StorageManager.gameVideoURL(for: game)
        if let size = try? await SlowMoComposer.displaySize(of: url), size.height > 0 {
            aspectRatio = size.width / size.height
        }
        seek(to: window.start)
        play()
        // Frames across the whole trimmable range, behind the handles.
        let step = bounds.duration / Double(Self.filmstripFrames)
        var frames: [UIImage] = []
        for index in 0..<Self.filmstripFrames {
            let time = bounds.start + step * (Double(index) + 0.5)
            if let image = await ThumbnailGenerator.frame(of: url, at: time, maxDimension: 160) {
                frames.append(image)
            }
        }
        filmstrip = frames
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        guard canTrim else { return }
        let now = player.currentTime().seconds
        if !now.isFinite || now < window.start || now >= window.end - 0.05 { seek(to: window.start) }
        player.play()
        isPlaying = true
    }

    private func pause() {
        player.pause()
        isPlaying = false
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Loops the preview inside the chosen range.
    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isDragging else { return }
                if time.seconds >= self.window.end { self.seek(to: self.window.start) }
            }
        }
    }

    // MARK: Editing

    /// Moves an edge while dragging: the preview shows that frame. No export.
    func drag(_ edge: ClipWindow.Edge, to seconds: Double) {
        guard canTrim, !isSaving else { return }
        if !isDragging {
            isDragging = true
            player.pause()
        }
        window = window.trimming(edge, to: seconds, within: bounds)
        seek(to: edge == .start ? window.start : window.end)
    }

    /// Done dragging: play the new range from its start.
    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        seek(to: window.start)
        if isPlaying { player.play() }
    }

    func resetToDefault() {
        guard canTrim, !isSaving else { return }
        window = defaultWindow
        seek(to: window.start)
        if isPlaying { player.play() }
    }

    // MARK: Saving

    /// Re-cuts the clip from the full game video. Returns true when the clip now has the new range.
    func save(context: ModelContext) async -> Bool {
        guard canSave else { return false }
        pause()
        isSaving = true
        saveProgress = 0
        defer { isSaving = false }
        do {
            try await ClipExtractor.trim(clip, to: window, context: context) { [weak self] value in
                self?.saveProgress = value
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}
