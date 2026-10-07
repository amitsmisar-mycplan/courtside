import AVFoundation
import OSLog
import QuartzCore
import SwiftData

/// Drives live recording: creates the `Game`, writes `Mark` rows as the parent taps, and
/// makes sure every way recording can end leaves a saved game.
@MainActor @Observable
final class RecordingSession {
    enum Phase: Equatable {
        case preparing
        case ready
        case recording
        case finishing
        case finished
        case failed(String)
    }

    private static let log = Logger(subsystem: "Courtside", category: "Recording")
    static let debounceInterval: CFTimeInterval = 2
    static let undoWindow: Duration = .seconds(5)
    static let idleDimAfter: CFTimeInterval = 30
    static let lowDiskStopBytes: Int64 = 1_000_000_000
    static let diskPollInterval: Duration = .seconds(60)

    private(set) var phase: Phase = .preparing
    private(set) var failureNeedsSettings = false
    private(set) var preflightIssues: [RecordingPreflight.Issue] = []
    private(set) var elapsed: Double = 0
    private(set) var markCount = 0
    private(set) var undoableMark: Mark?
    private(set) var isDimmed = false
    private(set) var thermalWarning: String?
    private(set) var game: Game?
    /// Why recording stopped, when the parent didn't stop it.
    private(set) var endNote: String?

    @ObservationIgnored let service: RecordingService
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let freeSpace: () -> Int64
    @ObservationIgnored private let clock: () -> CFTimeInterval
    @ObservationIgnored private var lastMarkAt: CFTimeInterval = -.greatestFiniteMagnitude
    @ObservationIgnored private var lastInteraction: CFTimeInterval = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var diskTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    init(
        service: RecordingService,
        context: ModelContext,
        freeSpace: @escaping () -> Int64 = StorageManager.availableCapacity,
        clock: @escaping () -> CFTimeInterval = CACurrentMediaTime
    ) {
        self.service = service
        self.context = context
        self.freeSpace = freeSpace
        self.clock = clock
    }

    var canStart: Bool {
        phase == .ready && !preflightIssues.contains(where: \.blocksRecording)
    }

    // MARK: Lifecycle

    func prepare(preflight: [RecordingPreflight.Issue]) async {
        preflightIssues = preflight
        service.onUnexpectedFinish = { [weak self] url, duration in
            self?.recordingEndedUnexpectedly(url: url, duration: duration)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            MainActor.assumeIsolated { self?.thermalWarning = RecordingPreflight.thermalWarning(for: state) }
        }
        thermalWarning = RecordingPreflight.thermalWarning(for: ProcessInfo.processInfo.thermalState)
        do {
            try await service.prepare()
            phase = .ready
        } catch {
            failureNeedsSettings = (error as? RecordingError)?.needsSettings ?? false
            phase = .failed(error.localizedDescription)
        }
    }

    func start() async {
        guard canStart else { return }
        do {
            let url = try await service.startRecording()
            let now = Date()
            // Created as soon as the file exists, so a crash mid-game still has a record.
            let game = Game(
                label: Game.defaultLabel(for: now),
                recordedAt: now,
                videoFilename: url.lastPathComponent,
                durationSeconds: 0,
                source: .recorded,
                videoFileSize: 0
            )
            context.insert(game)
            try? context.save()
            self.game = game
            phase = .recording
            touch()
            startTicking()
            startWatchingDisk()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops and saves. `reason` is shown afterwards when the parent didn't choose to stop.
    func stop(reason: String? = nil) async {
        guard phase == .recording else { return }
        phase = .finishing
        endNote = reason
        stopBackgroundWork()
        do {
            let result = try await service.stopRecording()
            await finalize(url: result.url, reportedDuration: result.duration)
        } catch {
            // Recording had already ended on its own; save what's there.
            Self.log.error("Stop failed: \(error.localizedDescription); saving what was recorded")
            if let game {
                await finalize(url: StorageManager.gameVideoURL(for: game), reportedDuration: elapsed)
            }
        }
    }

    /// Leaving the screen (backgrounding) stops and saves, rather than risking the file.
    func handleBackground() async {
        await stop(reason: "Recording stopped when Courtside left the screen. Everything up to that point is saved.")
    }

    func checkDiskSpace() async {
        guard phase == .recording, freeSpace() < Self.lowDiskStopBytes else { return }
        await stop(reason: "Recording stopped because the phone is almost out of space. Everything up to that point is saved.")
    }

    func shutdown() {
        stopBackgroundWork()
        undoExpiry?.cancel()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        service.shutdown()
    }

    private func recordingEndedUnexpectedly(url: URL, duration: Double) {
        guard phase == .recording else { return }
        phase = .finishing
        stopBackgroundWork()
        endNote = "Recording stopped on its own — usually a phone call or the camera being needed elsewhere. Everything up to that point is saved."
        Task { await finalize(url: url, reportedDuration: duration) }
    }

    private func finalize(url: URL, reportedDuration: Double) async {
        guard let game else {
            phase = .finished
            return
        }
        let asset = AVURLAsset(url: url)
        let loaded = (try? await asset.load(.duration).seconds) ?? 0
        let duration = loaded.isFinite && loaded > 0 ? loaded : max(reportedDuration, elapsed)
        game.durationSeconds = duration
        game.videoFileSize = StorageManager.fileSize(at: url)
        try? context.save()
        elapsed = duration
        undoableMark = nil
        isDimmed = false
        phase = .finished
        Self.log.info("Saved recording: \(duration)s, \(self.markCount) marks")
    }

    // MARK: Marking

    /// Records a mark at the current recording time. Returns false if debounced or not recording.
    @discardableResult
    func placeMark() -> Bool {
        guard phase == .recording, let game else { return false }
        touch()
        let now = clock()
        guard now - lastMarkAt >= Self.debounceInterval else { return false }
        lastMarkAt = now

        let mark = Mark(offsetSeconds: service.mark())
        context.insert(mark)
        mark.game = game
        try? context.save()
        markCount += 1

        undoableMark = mark
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.undoableMark = nil
        }
        return true
    }

    func undoLastMark() {
        guard let mark = undoableMark else { return }
        touch()
        undoExpiry?.cancel()
        undoableMark = nil
        context.delete(mark)
        try? context.save()
        markCount = max(0, markCount - 1)
        lastMarkAt = -.greatestFiniteMagnitude
    }

    func refocus() {
        touch()
        service.refocus()
    }

    /// Any interaction wakes the screen and restarts the idle clock.
    func touch() {
        lastInteraction = clock()
        isDimmed = false
    }

    /// Updates elapsed time and the idle dim. Called twice a second while recording.
    func tick() {
        guard phase == .recording else { return }
        elapsed = service.mark()
        if !isDimmed, clock() - lastInteraction >= Self.idleDimAfter {
            isDimmed = true
        }
    }

    // MARK: Background work

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startWatchingDisk() {
        diskTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.diskPollInterval)
                guard !Task.isCancelled else { return }
                await self?.checkDiskSpace()
            }
        }
    }

    private func stopBackgroundWork() {
        tickTask?.cancel()
        diskTask?.cancel()
        tickTask = nil
        diskTask = nil
    }
}
