import AVFoundation
import SwiftUI

/// Shows the live camera. Holds only the preview layer; the session stays inside the controller.
struct CameraPreview: UIViewRepresentable {
    let source: CameraPreviewSource

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        // Aspect-fit: the parent sees exactly what's being recorded.
        view.previewLayer.videoGravity = .resizeAspect
        source.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
