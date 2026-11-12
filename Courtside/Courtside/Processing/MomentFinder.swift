import Foundation
import OSLog
import SwiftData
import UIKit

/// "Find Moments" (decision 0029): listens to one part's video and saves the moments the crowd
/// reacted to as `SuggestedMoment`s for the parent to review. Analysis only: it never exports,
/// never touches the video file, and never makes a mark or clip by itself.
///
/// One scan at a time across the app. It runs off the main thread, stops when cancelled, and
/// stops cleanly when iOS ends the app's background time; what it heard so far is saved, so the
/// next start picks up from there.
@MainActor @Observable
final class MomentFinder {
    enum Phase: Equatable {
        case idle
        case running
        /// Done; the part's suggestions are saved.
        case finished
        /// Stopped by the parent. What was heard is kept for next time.
        case cancelled
        /// Stopped because iOS ended the app's background time; resumes when back on screen.
        case interrupted
        case failed(String)
    }

    nonisolated private static let log = Logger(subsystem: "Courtside", category: "Moments")
    private static var isBusy = false

    private(set) var phase: Phase = .idle
    /// Share of the video listened to, 0...1.
    private(set) var progress: Double = 0
    /// New suggestions from the last finished scan.
    private(set) var found = 0

    @ObservationIgnored private let backgroundTime: BackgroundTimeGranting
    @ObservationIgnored private let settings: MomentPicker.Settings
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier?
    @ObservationIgnored private var backgroundTimeExpired = false

    init(backgroundTime: BackgroundTimeGranting = SystemBackgroundTime(), settings: MomentPicker.Settings = MomentPicker.Settings()) {
        self.backgroundTime = backgroundTime
        self.settings = settings
    }

    /// Listens to `part`'s video, from where an earlier scan stopped. Returns false if a scan is
    /// already running anywhere in the app or the video isn't there.
    @discardableResult
    func start(part: GamePart, context: ModelContext) -> Bool {
        guard phase != .running, !Self.isBusy, part.isVideoAvailable else { return false }
        Self.isBusy = true
        phase = .running
        found = 0
        backgroundTimeExpired = false
        let resume = StorageManager.loadMomentScan(forPartID: part.id) ?? MomentSignal()
        progress = part.durationSeconds > 0 ? min(1, Double(resume.count) / part.durationSeconds) : 0
        backgroundTask = backgroundTime.begin(name: "FindMoments") { [weak self] in
            self?.backgroundTimeRanOut()
        }
        runTask = Task { await run(part: part, resume: resume, context: context) }
        return true
    }

    func cancel() {
        switch phase {
        case .running: runTask?.cancel()
        case .interrupted: phase = .cancelled
        default: break
        }
    }

    /// Waits for the current scan to end (tests).
    func waitUntilDone() async {
        await runTask?.value
    }

    private func backgroundTimeRanOut() {
        Self.log.info("Background time ran out; pausing Find Moments")
        if phase == .running {
            backgroundTimeExpired = true
            runTask?.cancel()
        }
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard let task = backgroundTask else { return }
        backgroundTask = nil
        backgroundTime.end(task)
    }

    private func run(part: GamePart, resume: MomentSignal, context: ModelContext) async {
        defer {
            endBackgroundTime()
            Self.isBusy = false
        }
        let partID = part.id
        let url = StorageManager.videoURL(for: part)
        let started = Date()
        do {
            let result = try await MomentListener.listen(
                to: url,
                resuming: resume,
                progress: { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.phase == .running else { return }
                        self.progress = value
                    }
                },
                checkpoint: { signal in StorageManager.saveMomentScan(signal, forPartID: partID) }
            )
            guard result.isComplete else {
                StorageManager.saveMomentScan(result.signal, forPartID: partID)
                Self.log.info("Find Moments stopped after \(result.signal.count)s")
                phase = backgroundTimeExpired ? .interrupted : .cancelled
                return
            }
            // The part or its video may have gone while listening.
            guard part.modelContext != nil, part.isVideoAvailable else {
                StorageManager.removeMomentScan(forPartID: partID)
                phase = .cancelled
                return
            }
            let marks = (part.game?.marks ?? []).filter { $0.resolvedPart === part }.map(\.offsetSeconds)
            let settings = settings
            let candidates = await Task.detached(priority: .utility) {
                MomentPicker.pick(result.signal, avoiding: marks, settings: settings)
            }.value
            found = Self.save(candidates, to: part, spacing: settings.spacing, context: context)
            StorageManager.removeMomentScan(forPartID: partID)
            let seconds = Date().timeIntervalSince(started)
            Self.log.info("Find Moments: \(result.signal.count)s of audio in \(seconds, format: .fixed(precision: 1))s, \(self.found) suggestions")
            progress = 1
            phase = .finished
        } catch {
            Self.log.error("Find Moments failed: \(error.localizedDescription)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Courtside couldn't listen to this video.")
        }
    }

    /// Replaces the part's pending suggestions with `candidates`. Moments the parent already
    /// accepted or dismissed stay as they are, and nothing new is suggested near them. Returns how
    /// many were added.
    @discardableResult
    static func save(_ candidates: [MomentPicker.Candidate], to part: GamePart, spacing: Double, context: ModelContext) -> Int {
        for moment in part.suggestions where moment.status == .pending {
            context.delete(moment)
        }
        let decided = part.suggestions.filter { $0.status != .pending }.map(\.seconds)
        var added = 0
        for candidate in candidates where !decided.contains(where: { abs($0 - candidate.seconds) < spacing }) {
            let moment = SuggestedMoment(seconds: candidate.seconds, score: candidate.score, sound: candidate.sound)
            context.insert(moment)
            moment.part = part
            added += 1
        }
        part.momentsFoundAt = .now
        try? context.save()
        return added
    }
}
