import Foundation

/// The back lenses the recorder can use (decision 0026). No AVFoundation here, so views and tests can
/// use it; `CaptureSessionController` maps it to a camera.
enum CameraLens: String, CaseIterable, Sendable {
    /// 0.5×: about twice the horizontal field of view, so a tripod at the sideline sees the whole court.
    case ultraWide
    /// 1×: the main camera.
    case wide

    /// The label the Camera app uses.
    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        }
    }

    var spokenName: String {
        switch self {
        case .ultraWide: "Ultra wide lens"
        case .wide: "Main lens"
        }
    }
}

/// Which lens to record with, and the parent's last choice.
enum LensSettings {
    static let key = "recordingLens"

    /// The lens chosen last time, or nil if never chosen.
    static func saved(in defaults: UserDefaults = .standard) -> CameraLens? {
        defaults.string(forKey: key).flatMap(CameraLens.init(rawValue:))
    }

    static func save(_ lens: CameraLens, in defaults: UserDefaults = .standard) {
        defaults.set(lens.rawValue, forKey: key)
    }

    /// The saved choice if this phone has that lens; otherwise ultra-wide if it has one, else the main
    /// camera. Nil only when the phone has neither.
    static func choose(saved: CameraLens?, available: [CameraLens]) -> CameraLens? {
        if let saved, available.contains(saved) { return saved }
        if available.contains(.ultraWide) { return .ultraWide }
        return available.contains(.wide) ? .wide : nil
    }
}
