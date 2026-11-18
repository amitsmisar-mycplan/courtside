import CoreGraphics

/// Wide / Medium / Tight for a Vertical export of a landscape clip (decision 0032): three zooms on
/// decision 0024's scale, chosen by how much of the video's width the 9:16 frame keeps. The zoom
/// math is `VerticalFraming`'s; this only picks points on it.
enum FramingPreset: String, CaseIterable, Identifiable {
    case wide, medium, tight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: "Wide"
        case .medium: "Medium"
        case .tight: "Tight"
        }
    }

    /// The share of the video's width the frame aims to keep; nil for Tight (as close as the clip allows).
    var targetWidthShare: Double? {
        switch self {
        case .wide: 2.0 / 3
        case .medium: 0.5
        case .tight: nil
        }
    }

    /// The zoom (0...1 on decision 0024's scale) that keeps `targetWidthShare` of the width, held
    /// to what the video's resolution allows. Tight is that limit.
    func zoom(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> Double {
        let limit = VerticalFraming.maxZoom(videoSize: videoSize, canvas: canvas)
        guard let share = targetWidthShare, videoSize.width > 0 else { return limit }
        // The frame keeps canvas.width / scale video pixels across, so this share needs this scale.
        let scale = canvas.width / (CGFloat(share) * videoSize.width)
        let fit = VerticalFraming.scale(zoom: 0, videoSize: videoSize, canvas: canvas)
        let fill = VerticalFraming.scale(zoom: 1, videoSize: videoSize, canvas: canvas)
        guard fill > fit else { return 0 }
        let zoom = Double((scale - fit) / (fill - fit))
        return min(max(zoom, 0), limit)
    }

    /// The presets that differ on this clip, widest first. A low-resolution clip can't zoom far,
    /// so Tight (or even Medium) may land on the same zoom as the one before it: those are left out.
    static func distinct(videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> [FramingPreset] {
        var result: [FramingPreset] = []
        var last: Double?
        for preset in allCases {
            let zoom = preset.zoom(videoSize: videoSize, canvas: canvas)
            if let last, abs(zoom - last) < 0.01 { continue }
            result.append(preset)
            last = zoom
        }
        return result
    }

    /// Where a new Vertical starts: Medium, or the closest wider preset when the clip can't zoom that far.
    static func starting(videoSize: CGSize) -> FramingPreset {
        let medium = FramingPreset.medium.zoom(videoSize: videoSize)
        return distinct(videoSize: videoSize).last { $0.zoom(videoSize: videoSize) <= medium + 0.005 } ?? .wide
    }

    /// The share of the video's width the frame keeps at `zoom` (1 = the whole width).
    static func widthShare(zoom: Double, videoSize: CGSize, canvas: CGSize = ExportFormat.verticalRenderSize) -> Double {
        let window = VerticalFraming.windowSize(zoom: zoom, videoSize: videoSize, canvas: canvas)
        return min(Double(window.width / max(videoSize.width, 1)), 1)
    }
}
