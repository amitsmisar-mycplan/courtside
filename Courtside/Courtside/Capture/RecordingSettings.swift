import Foundation

/// Recording preferences (decision 0035).
enum RecordingSettings {
    static let dimWhileRecordingKey = "dimScreenWhileRecording"

    /// "Dim screen while recording" in Settings; on unless switched off.
    static func dimsWhileRecording(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: dimWhileRecordingKey) as? Bool ?? true
    }
}
