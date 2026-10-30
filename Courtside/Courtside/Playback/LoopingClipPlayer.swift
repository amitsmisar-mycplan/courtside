import AVFoundation

/// Loops a single clip file.
@MainActor @Observable
final class LoopingClipPlayer {
    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Set when the clip can't be played, so the screen says so instead of staying black.
    private(set) var playbackFailed = false

    func load(_ url: URL) {
        player.pause()
        looper?.disableLooping()
        statusObservation?.invalidate()
        player.removeAllItems()
        playbackFailed = false
        // A fresh asset each time, so a clip re-exported in place is re-read from disk.
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        statusObservation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor in
                // Ignore a failure from a looper that has since been replaced.
                guard let self, self.looper === looper else { return }
                self.player.pause()
                self.playbackFailed = true
            }
        }
        player.play()
    }

    func pause() {
        player.pause()
    }
}
