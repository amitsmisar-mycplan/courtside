import AVFoundation

/// Loops a single clip file.
@MainActor @Observable
final class LoopingClipPlayer {
    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?

    func load(_ url: URL) {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
        // A fresh asset each time, so a clip re-exported in place is re-read from disk.
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    func pause() {
        player.pause()
    }
}
