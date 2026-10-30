import AVFoundation
import CoreImage
import ImageIO

/// Turns an `ExportPlan` into what `ClipExtractor` exports: the asset and, when frames change,
/// an `AVMutableVideoComposition` that draws each one with Core Image.
enum ExportComposer {
    /// Blur for the vertical background, in output pixels.
    static let backgroundBlurRadius: Double = 36
    /// Slightly darker background, so the sharp video in front reads as the subject.
    static let backgroundBrightness: Double = -0.08

    struct Output {
        let asset: AVAsset
        /// Nil when frames pass through unchanged.
        let videoComposition: AVVideoComposition?
    }

    static func build(_ plan: ExportPlan) async throws -> Output {
        let asset = AVURLAsset(url: plan.source)
        // Timeline steps (end card) will extend `asset` here, before the frames are laid out.
        guard plan.format == .vertical || !plan.frameSteps.isEmpty else {
            return Output(asset: asset, videoComposition: nil)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SlowMoError.noVideoTrack
        }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let orientation = orientation(of: transform)
        let videoSize = displaySize(naturalSize: naturalSize, orientation: orientation)

        let canvas: CGSize = plan.format == .vertical ? ExportFormat.verticalRenderSize : videoSize
        let foreground = plan.format == .vertical
            ? VerticalLayout.foreground(videoSize: videoSize, canvas: canvas)
            : CGRect(origin: .zero, size: canvas)
        let background: CGRect? = plan.format == .vertical && foreground.size != canvas
            ? VerticalLayout.background(videoSize: videoSize, canvas: canvas)
            : nil
        let steps = plan.frameSteps
        let canvasRect = CGRect(origin: .zero, size: canvas)

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = upright(request.sourceImage, orientation: orientation, videoSize: videoSize)
            var output = place(frame, in: foreground)
            if let background {
                output = output.composited(over: blurredBackground(frame, in: background, canvas: canvasRect))
            }
            output = output.cropped(to: canvasRect)
            let time = request.compositionTime.seconds
            for step in steps {
                output = step.apply(to: output, canvas: canvasRect, time: time).cropped(to: canvasRect)
            }
            request.finish(with: output, context: nil)
        }
        composition.renderSize = canvas
        let fps = frameRate > 0 ? frameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        return Output(asset: asset, videoComposition: composition)
    }

    // MARK: Orientation

    /// The track's rotation as an image orientation. Phones filming upright store a 90° turn.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    private static func displaySize(naturalSize: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            CGSize(width: abs(naturalSize.height), height: abs(naturalSize.width))
        default:
            CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
        }
    }

    /// Frames as the video is meant to be watched, origin at zero. AVFoundation hands the filter
    /// frames with the track's rotation already applied (checked by test for 0°, ±90° and 180°);
    /// the shape check only guards against a quarter turn arriving unapplied.
    private static func upright(_ image: CIImage, orientation: CGImagePropertyOrientation, videoSize: CGSize) -> CIImage {
        let stored = image.extent.size
        let hasStoredShape = abs(stored.width - videoSize.width) >= 1 || abs(stored.height - videoSize.height) >= 1
        let isQuarterTurn = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let oriented = isQuarterTurn && hasStoredShape ? image.oriented(orientation) : image
        return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    }

    // MARK: Layout

    private static func place(_ image: CIImage, in rect: CGRect) -> CIImage {
        let scale = CGAffineTransform(scaleX: rect.width / max(image.extent.width, 1), y: rect.height / max(image.extent.height, 1))
        return image.transformed(by: scale.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private static func blurredBackground(_ image: CIImage, in rect: CGRect, canvas: CGRect) -> CIImage {
        place(image, in: rect)
            // Extend the edges so the blur doesn't fade to transparent at the borders.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: backgroundBlurRadius)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: backgroundBrightness])
            .cropped(to: canvas)
    }
}
