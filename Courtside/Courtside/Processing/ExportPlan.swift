import CoreGraphics
import CoreImage
import Foundation

/// What the parent picks when exporting a clip for posting.
enum ExportFormat: String, CaseIterable, Identifiable {
    /// The clip as it is (16:9 for footage filmed sideways).
    case original
    /// 1080×1920 for Instagram Reels and TikTok: the video fit to the width over a blurred copy of itself.
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .vertical: "Vertical"
        }
    }

    /// `sourceSize` is the clip as shown; the Original label names its real shape.
    func detail(sourceSize: CGSize?) -> String {
        switch self {
        case .original:
            // Until the clip's shape is known, the usual 16:9.
            let ratio: String? = if let sourceSize { Self.ratioLabel(sourceSize) } else { "16:9" }
            guard let ratio else { return "The clip as it is" }
            return "The clip as it is · \(ratio)"
        case .vertical:
            return "For Instagram and TikTok · 9:16"
        }
    }

    /// "16:9", "9:16", or nil for other shapes.
    static func ratioLabel(_ size: CGSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        if abs(ratio - 16.0 / 9) < 0.05 { return "16:9" }
        if abs(ratio - 9.0 / 16) < 0.05 { return "9:16" }
        return nil
    }

    static let verticalRenderSize = CGSize(width: 1080, height: 1920)
}

/// One per-frame drawing step, applied in order on top of the layout. The watermark (feature 7)
/// slots in here. `canvas` is the output frame, origin bottom-left as in Core Image.
protocol ExportFrameStep: Sendable {
    func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage
}

/// Everything an export does, in pipeline order:
///
/// 1. **Source** — the file to start from: the clip, or its rendered slow-mo version (feature 9's
///    output is a file today; a slow-mo *step* would build an `AVComposition` from this source).
/// 2. **Timeline** — reserved for steps that change length, such as an end card (feature 7). None yet.
/// 3. **Layout** — the output frame: as-is, or vertical with a blurred background.
/// 4. **Frame steps** — drawn over each laid-out frame (watermark).
/// 5. **Export** — `ClipExtractor`, HEVC Highest Quality, never passthrough.
struct ExportPlan {
    var source: URL
    var format: ExportFormat
    var frameSteps: [ExportFrameStep] = []

    /// True when the output would be the source file unchanged, so it can be saved without re-encoding.
    var isUnchangedSource: Bool { format == .original && frameSteps.isEmpty }
}

/// Where the foreground and background go in a vertical frame. Pure geometry, origin bottom-left.
enum VerticalLayout {
    /// The video scaled to fit the canvas (full width for landscape footage), centered.
    static func foreground(videoSize: CGSize, canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / max(videoSize.width, 1), canvas.height / max(videoSize.height, 1))
        return centered(CGSize(width: videoSize.width * scale, height: videoSize.height * scale), in: canvas)
    }

    /// The video scaled to cover the whole canvas, centered (cropped at the edges), behind the blur.
    static func background(videoSize: CGSize, canvas: CGSize) -> CGRect {
        let scale = max(canvas.width / max(videoSize.width, 1), canvas.height / max(videoSize.height, 1))
        return centered(CGSize(width: videoSize.width * scale, height: videoSize.height * scale), in: canvas)
    }

    private static func centered(_ size: CGSize, in canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }
}
