import CoreImage
import CoreText
import UIKit

/// An image drawn over the video during set windows, fading in and out. The shared overlay
/// mechanism (decision 0019): the game label uses it now; a watermark is the same thing with one
/// window covering the whole clip.
struct TimedOverlay: ExportFrameStep, @unchecked Sendable {
    /// Already placed on the canvas (origin bottom-left, as in Core Image).
    let image: CIImage
    let windows: [OverlayWindow]
    var fade: Double = LabelTiming.fade

    func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage {
        let opacity = LabelTiming.opacity(at: time, windows: windows, fade: fade)
        guard opacity > 0 else { return image }
        var overlay = self.image
        if opacity < 1 {
            // Premultiplied colour: scale every channel to fade.
            let a = CGFloat(opacity)
            overlay = overlay.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            ])
        }
        return overlay.composited(over: image)
    }
}

/// The game label, drawn once the output frame and length are known: 2.5 s at the open and close
/// (open only under 7 s), placed by the exported file's own length, so trims and slow mo get it right.
struct LabelStep: ExportFrameStep {
    let label: LabelText

    /// The parts the label is built from, kept apart so long names can be shortened to fit.
    struct LabelText: Hashable, Sendable {
        var team: String?
        var opponent: String?
        var tournament: String?
        var date: Date?
    }

    func prepared(canvas: CGSize, duration: Double) -> ExportFrameStep {
        guard let image = LabelRenderer.image(for: label, canvas: canvas) else { return NoStep() }
        return TimedOverlay(image: image, windows: LabelTiming.windows(duration: duration))
    }

    /// Only drawn once prepared.
    func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage { image }

    private struct NoStep: ExportFrameStep {
        func apply(to image: CIImage, canvas: CGRect, time: Double) -> CIImage { image }
    }
}

/// Where the label box goes and how big its text is, from the output frame. Pure geometry.
struct LabelPlacement: Equatable {
    let titleSize: CGFloat
    let detailSize: CGFloat
    let padding: CGSize
    let lineGap: CGFloat
    let cornerRadius: CGFloat
    /// Lower-left corner of the box, origin bottom-left.
    let origin: CGPoint
    /// The whole box, padding included, never wider than this (70 % of the frame).
    let maxBoxWidth: CGFloat

    static let maxWidthFraction: CGFloat = 0.7

    init(canvas: CGSize) {
        let unit = min(canvas.width, canvas.height)
        titleSize = unit * 0.036
        detailSize = unit * 0.028
        padding = CGSize(width: unit * 0.022, height: unit * 0.016)
        lineGap = unit * 0.008
        cornerRadius = unit * 0.02
        maxBoxWidth = canvas.width * Self.maxWidthFraction
        if canvas.height > canvas.width {
            // 9:16: above the band where Instagram and TikTok put the caption and account name
            // (bottom ~20 %), and short of their buttons on the right (the box ends by 76 % across).
            origin = CGPoint(x: canvas.width * 0.06, y: canvas.height * 0.22)
        } else {
            // Inside a 5 % safe margin.
            origin = CGPoint(x: canvas.width * 0.05, y: canvas.height * 0.05)
        }
    }

    var maxTextWidth: CGFloat { maxBoxWidth - padding.width * 2 }
}

/// Draws the label box with Core Text: white text on a dark, semi-transparent rounded box.
enum LabelRenderer {
    static let boxOpacity: CGFloat = 0.55

    static func image(for text: LabelStep.LabelText, canvas: CGSize) -> CIImage? {
        let placement = LabelPlacement(canvas: canvas)
        let fonts = [
            UIFont.systemFont(ofSize: placement.titleSize, weight: .semibold),
            UIFont.systemFont(ofSize: placement.detailSize, weight: .regular),
        ]
        func line(_ string: String, _ index: Int) -> CTLine {
            let font = fonts[min(index, 1)]
            let color = UIColor(white: 1, alpha: index == 0 ? 1 : 0.85)
            return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color,
            ]))
        }
        guard let label = GameLabel.fitted(
            team: text.team, opponent: text.opponent, tournament: text.tournament, date: text.date,
            maxWidth: placement.maxTextWidth,
            measure: { width(of: line($0, $1)) }
        ) else { return nil }

        // A line's index in the font list: the matchup line uses the title font only when it exists.
        let hasMatchup = text.team?.nonEmpty != nil || text.opponent?.nonEmpty != nil
        let lines = label.lines.enumerated().map { line($1, hasMatchup ? $0 : 1) }
        let heights = lines.map(height(of:))
        let textWidth = lines.map(width(of:)).max() ?? 0
        let boxSize = CGSize(
            width: ceil(min(textWidth + placement.padding.width * 2, placement.maxBoxWidth)),
            height: ceil(heights.reduce(0, +) + placement.lineGap * CGFloat(lines.count - 1) + placement.padding.height * 2)
        )
        guard boxSize.width >= 1, boxSize.height >= 1,
              let context = CGContext(
                data: nil, width: Int(boxSize.width), height: Int(boxSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let box = CGRect(origin: .zero, size: boxSize)
        context.addPath(CGPath(roundedRect: box, cornerWidth: placement.cornerRadius, cornerHeight: placement.cornerRadius, transform: nil))
        context.setFillColor(UIColor(white: 0, alpha: boxOpacity).cgColor)
        context.fillPath()

        // Core Graphics' origin is bottom-left: the first line goes at the top.
        var top = boxSize.height - placement.padding.height
        for (line, lineHeight) in zip(lines, heights) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            context.textPosition = CGPoint(x: placement.padding.width, y: top - ascent)
            CTLineDraw(line, context)
            top -= lineHeight + placement.lineGap
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: placement.origin.x, y: placement.origin.y))
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func height(of line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ascent + descent
    }
}

extension LabelStep.LabelText {
    /// The label parts of a game, or nil when the setting is Off or there's nothing to show.
    @MainActor static func forExport(game: Game?, mode: ExportLabelMode = LabelSettings.exportLabel) -> Self? {
        guard GameLabel.forExport(game: game, mode: mode) != nil, let game else { return nil }
        return Self(team: game.team, opponent: game.opponent, tournament: game.tournament, date: game.recordedAt)
    }
}
