#if DEBUG
import Foundation

/// One verdict from the debug screen (decision 0027).
struct FollowVerdict: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable { case stayed, lost }
    enum Scene: String, Codable, CaseIterable, Sendable {
        case openCourt, crowdedPaint, other
        var title: String {
            switch self {
            case .openCourt: "Open court"
            case .crowdedPaint: "Crowded paint"
            case .other: "Other"
            }
        }
    }

    var date: Date
    var clipID: UUID
    var result: Result
    var failureNote: String?
    var scene: Scene
    var mode: FollowMode
    var processingSeconds: Double
    var clipSeconds: Double
    var videoSize: String
    var trackedFPS: Double
    var framesTracked: Int
    var resnaps: Int
    /// Times Vision dropped the box and tracking restarted from the last one. Optional so older lines still read.
    var trackerRestarts: Int?
    var lowConfidenceFrames: Int
    var minConfidence: Double
    var meanConfidence: Double
    /// False when the tap wasn't on a detected person and a default-size box was used.
    var tapSnappedToBody: Bool
    var device: String
}

/// Append-only JSON-lines file of verdicts, in the app's own Application Support folder. Debug
/// only; not a model file, so it doesn't go through `StorageManager`.
struct TapToFollowLog {
    let url: URL

    static let standard = TapToFollowLog(url: URL.applicationSupportDirectory
        .appending(path: "Debug", directoryHint: .isDirectory)
        .appending(path: "tap-to-follow-log.jsonl"))

    func append(_ verdict: FollowVerdict) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var line = try encoder.encode(verdict)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// Every verdict, oldest first. Lines that don't parse are skipped.
    func verdicts() -> [FollowVerdict] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(FollowVerdict.self, from: Data($0.utf8)) }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The phone model ("iPhone17,1"), or the simulated one.
    static var deviceName: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "Simulator \(simulated)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// The success measure: the latest verdict for each clip.
struct FollowSummary: Equatable {
    var clips: Int
    var stayed: Int
    var latest: [UUID: FollowVerdict.Result]

    /// Success rate across clips, nil before any verdict.
    var rate: Double? { clips == 0 ? nil : Double(stayed) / Double(clips) }

    init(_ verdicts: [FollowVerdict]) {
        var latest: [UUID: FollowVerdict.Result] = [:]
        for verdict in verdicts.sorted(by: { $0.date < $1.date }) { latest[verdict.clipID] = verdict.result }
        self.latest = latest
        clips = latest.count
        stayed = latest.values.filter { $0 == .stayed }.count
    }
}
#endif
