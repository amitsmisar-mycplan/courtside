import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case noCamera
    case cameraDenied
    case microphoneDenied
    case configurationFailed(String)
    case alreadyRecording
    case notRecording
    case startFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "This device has no camera. Recording works on an iPhone; you can still import videos."
        case .cameraDenied:
            "Courtside doesn't have permission to use the camera. Turn it on in Settings → Courtside."
        case .microphoneDenied:
            "Courtside doesn't have permission to use the microphone. Turn it on in Settings → Courtside."
        case .configurationFailed(let detail):
            "The camera couldn't be set up (\(detail))."
        case .alreadyRecording:
            "Already recording."
        case .notRecording:
            "Not recording."
        case .startFailed:
            "Recording couldn't start. Try again."
        }
    }

    /// Errors the parent can fix in Settings.
    var needsSettings: Bool {
        switch self {
        case .cameraDenied, .microphoneDenied: true
        default: false
        }
    }
}

/// Live capture, behind a protocol so nothing outside `Capture/` depends on the camera
/// (and tests can use a fake). Extends the spec's three calls with set-up, refocus,
/// shutdown, and a callback for recordings that end without `stopRecording()`.
protocol RecordingService: AnyObject {
    /// Checks for a camera, asks for permissions, and starts the camera feed.
    func prepare() async throws
    /// Starts writing a new game video; returns its URL once the file has actually started.
    func startRecording() async throws -> URL
    func stopRecording() async throws -> (url: URL, duration: Double)
    /// Seconds since the file started, from `CACurrentMediaTime()` deltas (never `Date()`).
    func mark() -> Double
    /// Refocuses and re-meters the centre of the frame, then locks again after the settle.
    func refocus()
    /// Stops the camera feed. Call when leaving the recording screen.
    func shutdown()
    /// Called when recording ends on its own — a phone call, backgrounding, a camera error.
    /// Whatever was written is kept; the receiver must still save the game.
    var onUnexpectedFinish: (@MainActor (URL, Double) -> Void)? { get set }
}

/// Lets the preview view show the camera without ever touching `AVCaptureSession`.
protocol CameraPreviewSource: AnyObject {
    @MainActor func attachPreview(_ layer: AVCaptureVideoPreviewLayer)
}
