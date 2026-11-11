#if DEBUG
import CoreGraphics
import Foundation

/// Preview-only maths for a 9:16 window that follows the tracked box (decision 0027). Nothing is
/// exported; the debug screen just shows this window of the clip.
enum FollowCrop {
    /// How quickly the window catches up with the player. Longer is calmer but lags fast breaks.
    static let defaultTimeConstant = 0.4

    /// Width of a full-height 9:16 window as a fraction of the video's width; 1 when the video is
    /// already that narrow (a portrait clip needs no following).
    static func windowWidth(displaySize: CGSize) -> CGFloat {
        guard displaySize.width > 0 else { return 1 }
        return min(1, displaySize.height * 9 / 16 / displaySize.width)
    }

    /// One smoothed, clamped window centre per sample. Exponential smoothing run forwards then
    /// backwards, so the window neither lags nor leads the player and doesn't jitter with the box.
    static func smoothedCenters(
        times: [Double],
        xs: [Double],
        windowWidth: CGFloat,
        timeConstant: Double = defaultTimeConstant
    ) -> [Double] {
        guard times.count == xs.count, !xs.isEmpty else { return [] }
        func pass(_ values: [Double], _ times: [Double]) -> [Double] {
            var result = values
            for i in 1..<max(values.count, 1) {
                let dt = abs(times[i] - times[i - 1])
                let alpha = timeConstant > 0 ? 1 - exp(-dt / timeConstant) : 1
                result[i] = result[i - 1] + alpha * (values[i] - result[i - 1])
            }
            return result
        }
        let forward = pass(xs, times)
        let backward = Array(pass(forward.reversed(), times.reversed()).reversed())
        let half = Double(windowWidth) / 2
        return backward.map { min(max($0, half), 1 - half) }
    }

    /// The window, normalized to the frame.
    static func window(centerX: Double, windowWidth: CGFloat) -> CGRect {
        CGRect(x: CGFloat(centerX) - windowWidth / 2, y: 0, width: windowWidth, height: 1)
    }

    /// Where content of `size` sits when fitted inside `container` (letterboxed).
    static func fitted(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
#endif
