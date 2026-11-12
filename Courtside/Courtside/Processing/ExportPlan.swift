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
/// 3. **Layout** — the output frame: as-is, or vertical with a blurred background, zoomed and
///    aimed for landscape clips (decision 0024), the aim gliding between points (decision 0028).
/// 4. **Frame steps** — drawn over each laid-out frame: the game label (decision 0019), later the watermark.
/// 5. **Export** — `ClipExtractor`, HEVC Highest Quality, never passthrough; labelled exports at
///    "1080p (faster)" use the HEVC 1080p preset on a canvas capped at 1920 (decision 0021).
struct ExportPlan {
    var source: URL
    var format: ExportFormat
    var frameSteps: [ExportFrameStep] = []
    /// Longest side of the output in pixels, or nil for the source's own size (Vertical is always 1080×1920).
    var maxLongSide: CGFloat? = nil
    /// Vertical only: zoom and aim for a landscape clip (decision 0024). Nil is zoom 0, today's layout.
    var verticalFraming: VerticalFraming? = nil
    /// Vertical only: the aim over time, in seconds of `source` (decision 0028). Nil holds
    /// `verticalFraming`'s single aim for the whole clip, as before; set only when the aim moves.
    var aimPath: AimPath? = nil

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
    /// `framing` and `aim` apply to Vertical only and are ignored for Original. An aim that never
    /// moves (one point) becomes `framing`'s center, so it exports exactly as a single aim did.
    init(
        source: URL, format: ExportFormat, label: LabelStep.LabelText?, quality: LabelledExportQuality = .full,
        framing: VerticalFraming? = nil, aim: AimPath? = nil
    ) {
        var framing = format == .vertical ? framing : nil
        var path = framing == nil ? nil : aim
        if let fixed = path, fixed.isStatic {
            if let first = fixed.keys.first { framing?.center = first.center }
            path = nil
        }
        self.init(
            source: source,
            format: format,
            frameSteps: label.map { [LabelStep(label: $0)] } ?? [],
            maxLongSide: label != nil && quality == .hd1080 ? Self.cappedLongSide : nil,
            verticalFraming: framing,
            aimPath: path
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

/// Zoom and aim for a Vertical export of a landscape clip (decision 0024). Zoom 0 is the original
/// layout: the video fits the width over a blurred copy. Zoom 1 fills the 9:16 frame, cropping the
/// sides. In between, the scale moves evenly from one to the other. `center` is the middle of the
/// visible window in the video, 0...1 from the left and from the top.
struct VerticalFraming: Hashable, Sendable {
    var zoom: Double
    var center: CGPoint

    /// Today's layout.
    static let fitWidth = VerticalFraming(zoom: 0, center: CGPoint(x: 0.5, y: 0.5))
    /// The first default, before the parent has picked a zoom.
    static let defaultZoom = 0.6
    /// How far a source pixel may be stretched before the picture goes soft.
    static let maxUpscale: CGFloat = 1.5

    init(zoom: Double, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.zoom = zoom
        self.center = center
    }

    /// Only wider-than-tall clips are framed; portrait clips keep today's Vertical.
    static func applies(to videoSize: CGSize) -> Bool {
        videoSize.width > videoSize.height && videoSize.height > 0
    }

    /// Output pixels per video pixel at `zoom`: from fitting the width (0) to filling the frame (1).
    static func scale(zoom: Double, videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> CGFloat {
        let fit = canvas.width / max(videoSize.width, 1)
        let fill = max(fit, canvas.height / max(videoSize.height, 1))
        return fit + (fill - fit) * CGFloat(min(max(zoom, 0), 1))
    }

    /// The highest zoom that doesn't stretch the video more than `maxUpscale`: 1 for 4K, about
    /// 0.77 for a 1920×1080 clip, 0 when even fitting the width would stretch it that much.
    static func maxZoom(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> Double {
        let fit = scale(zoom: 0, videoSize: videoSize, canvas: canvas)
        let fill = scale(zoom: 1, videoSize: videoSize, canvas: canvas)
        guard fit < maxUpscale else { return 0 }
        guard fill > maxUpscale else { return 1 }
        return Double((maxUpscale - fit) / (fill - fit))
    }

    /// This framing with zoom held to `maxZoom` and the window kept inside the video.
    func clamped(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> VerticalFraming {
        let zoom = min(max(zoom, 0), Self.maxZoom(videoSize: videoSize, canvas: canvas))
        let window = Self.windowSize(zoom: zoom, videoSize: videoSize, canvas: canvas)
        func axis(_ value: CGFloat, window: CGFloat, video: CGFloat) -> CGFloat {
            // A window as big as the video (or bigger) can't move along that side.
            guard window < video else { return 0.5 }
            let half = window / video / 2
            return min(max(value, half), 1 - half)
        }
        return VerticalFraming(zoom: zoom, center: CGPoint(
            x: axis(center.x, window: window.width, video: videoSize.width),
            y: axis(center.y, window: window.height, video: videoSize.height)
        ))
    }

    /// Moved by a fraction of the video's size (a drag), then clamped.
    func moved(by delta: CGSize, videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> VerticalFraming {
        VerticalFraming(zoom: zoom, center: CGPoint(x: center.x + delta.width, y: center.y + delta.height))
            .clamped(videoSize: videoSize, canvas: canvas)
    }

    /// Size of the 9:16 output frame measured in video pixels.
    static func windowSize(zoom: Double, videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> CGSize {
        let scale = scale(zoom: zoom, videoSize: videoSize, canvas: canvas)
        return CGSize(width: canvas.width / scale, height: canvas.height / scale)
    }

    /// The part of the video the output shows, 0...1 from the top-left (for the sheet). Above and
    /// below the video, when the window is taller than it, is the blurred background.
    func window(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> CGRect {
        let framing = clamped(videoSize: videoSize, canvas: canvas)
        let size = Self.windowSize(zoom: framing.zoom, videoSize: videoSize, canvas: canvas)
        let width = size.width / videoSize.width, height = size.height / videoSize.height
        return CGRect(x: framing.center.x - width / 2, y: framing.center.y - height / 2, width: width, height: height)
    }

    /// Where the whole video goes in the output frame, origin bottom-left as in Core Image. Parts
    /// outside the canvas are cropped.
    func foreground(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> CGRect {
        let framing = clamped(videoSize: videoSize, canvas: canvas)
        let scale = Self.scale(zoom: framing.zoom, videoSize: videoSize, canvas: canvas)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let x = canvas.width / 2 - framing.center.x * size.width
        // `center.y` counts from the top; Core Image's y from the bottom.
        let y = size.height <= canvas.height
            ? (canvas.height - size.height) / 2
            : canvas.height / 2 - (1 - framing.center.y) * size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// For cache keys: two framings that look the same compare equal.
    var rounded: VerticalFraming {
        func round(_ value: Double, _ step: Double) -> Double { (value / step).rounded() * step }
        return VerticalFraming(zoom: round(zoom, 0.01), center: CGPoint(x: round(center.x, 0.001), y: round(center.y, 0.001)))
    }
}

/// The Vertical zoom the parent used last, offered again next time (decision 0024).
enum VerticalZoomSettings {
    static let lastZoomKey = "verticalLastZoom"

    static var lastZoom: Double {
        get { UserDefaults.standard.object(forKey: lastZoomKey) as? Double ?? VerticalFraming.defaultZoom }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: lastZoomKey) }
    }
}
