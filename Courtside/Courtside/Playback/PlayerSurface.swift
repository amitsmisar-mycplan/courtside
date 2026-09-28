import AVFoundation
import SwiftUI

/// Renders an `AVPlayer` with no built-in controls or gestures, so the whole surface can be
/// a tap target.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = videoGravity
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
