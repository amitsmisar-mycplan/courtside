import AVFoundation

/// Loops a single clip file, or one stretch of a longer video (a suggested moment, decision 0029).
@MainActor @Observable
final class LoopingClipPlayer {
    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Set when the clip can't be played, so the screen says so instead of staying black.
    private(set) var playbackFailed = false
    /// Width over height as the video is shown (its rotation applied); nil until known.
    private(set) var aspectRatio: Double?
    var isPortrait: Bool { (aspectRatio ?? 16 / 9) < 1 }
    @ObservationIgnored private var shapeTask: Task<Void, Never>?

    /// Plays `url` on a loop: the whole file, or just `range` of it (seconds).
    func load(_ url: URL, range: ClipWindow? = nil) {
        player.pause()
        looper?.disableLooping()
        statusObservation?.invalidate()
        player.removeAllItems()
        playbackFailed = false
        // A fresh asset each time, so a clip re-exported in place is re-read from disk.
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        shapeTask?.cancel()
        shapeTask = Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return }
            let shown = size.applying(transform)
            guard !Task.isCancelled, shown.height != 0 else { return }
            self?.aspectRatio = abs(shown.width / shown.height)
        }
        let looper = range.map {
            AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(
                start: CMTime(seconds: $0.start, preferredTimescale: 600),
                end: CMTime(seconds: $0.end, preferredTimescale: 600)
            ))
        } ?? AVPlayerLooper(player: player, templateItem: item)
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
