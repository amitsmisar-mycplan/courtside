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

/// One per-frame drawing step, applied in order on top of the layout: the game label now
/// (`LabelStep`, drawn by `TimedOverlay`), the watermark (feature 7) later. `canvas` is the output
/// frame, origin bottom-left as in Core Image; `time` is seconds into the exported video.
protocol ExportFrameStep: Sendable {
    /// Called once before the first frame, with the output size and length, so a step can draw what
    /// it needs once (a label image) and time itself by the final length. Defaults to `self`.
    func prepared(canvas: CGSize, duration: Double) -> ExportFrameStep
    func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage
}

extension ExportFrameStep {
    func prepared(canvas: CGSize, duration: Double) -> ExportFrameStep { self }
}

/// Everything an export does, in pipeline order:
///
/// 1. **Source** — the file to start from: the clip, or its rendered slow-mo version (feature 9's
///    output is a file today; a slow-mo *step* would build an `AVComposition` from this source).
/// 2. **Timeline** — reserved for steps that change length, such as an end card (feature 7). None yet.
/// 3. **Layout** — the output frame: as-is, or vertical with a blurred background.
/// 4. **Frame steps** — drawn over each laid-out frame: the game label (decision 0019), later the watermark.
/// 5. **Export** — `ClipExtractor`, HEVC Highest Quality, never passthrough; labelled exports at
///    "1080p (faster)" use the HEVC 1080p preset on a canvas capped at 1920 (decision 0021).
struct ExportPlan {
    var source: URL
    var format: ExportFormat
    var frameSteps: [ExportFrameStep] = []
    /// Longest side of the output in pixels, or nil for the source's own size (Vertical is always 1080×1920).
    var maxLongSide: CGFloat? = nil

    /// True when the output would be the source file unchanged, so it can be saved without re-encoding.
    var isUnchangedSource: Bool { format == .original && frameSteps.isEmpty }

    /// The 1080p cap: 1920 on the long side.
    static let cappedLongSide: CGFloat = 1920

    /// `size` scaled down to fit `maxLongSide` (never up), in even pixels as encoders want.
    static func cappedSize(_ size: CGSize, maxLongSide: CGFloat?) -> CGSize {
        guard let maxLongSide, size.width > 0, size.height > 0 else { return size }
        let scale = min(1, maxLongSide / max(size.width, size.height))
        guard scale < 1 else { return size }
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

extension ExportPlan {
    /// A clip's plan as Save to Photos and Share build it: the game label as a frame step when one
    /// applies, capped at 1080p when it does and the quality setting says so. Without a label nothing
    /// changes: the fast path and unlabelled Vertical keep today's quality.
    init(source: URL, format: ExportFormat, label: LabelStep.LabelText?, quality: LabelledExportQuality = .full) {
        self.init(
            source: source,
            format: format,
            frameSteps: label.map { [LabelStep(label: $0)] } ?? [],
            maxLongSide: label != nil && quality == .hd1080 ? Self.cappedLongSide : nil
        )
    }
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
