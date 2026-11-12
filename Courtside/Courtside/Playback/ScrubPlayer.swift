import AVFoundation

/// Plays one file from a scrub bar: exact seeks while dragging, play and pause, and the current
/// time for whatever is drawn over the video (the aim editor, decision 0028).
@MainActor @Observable
final class ScrubPlayer {
    @ObservationIgnored let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// While a seek runs, the latest one asked for waits here (dragging asks many times a second).
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: Double?

    func load(_ url: URL) async {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        duration = (try? await item.asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        currentTime = 0
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    self.currentTime = min(max(time.seconds, 0), self.duration)
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    /// Pauses and shows the frame at `seconds`.
    func seek(to seconds: Double) {
        pause()
        currentTime = min(max(seconds, 0), duration)
        pendingSeek = currentTime
        seekNext()
    }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        isPlaying = true
        player.play()
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Stops playback and observers; the sheet is closing.
    func stop() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func seekNext() {
        guard !isSeeking, let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.seekNext()
            }
        }
    }
}
