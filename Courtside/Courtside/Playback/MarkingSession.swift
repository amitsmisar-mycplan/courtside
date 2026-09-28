import AVFoundation
import QuartzCore
import SwiftData

/// Plays a game full-screen and turns taps into `Mark` rows.
@MainActor @Observable
final class MarkingSession {
    static let debounceInterval: CFTimeInterval = 2
    static let undoWindow: Duration = .seconds(5)
    static let speeds: [Float] = [1, 1.5, 2]
    static let jumpBackSeconds: Double = 10

    struct Tick: Identifiable {
        let id: UUID
        let offset: Double
    }

    let game: Game
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored private let context: ModelContext

    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var speed: Float = 1
    /// The most recent mark, while it can still be undone.
    private(set) var undoableMark: Mark?
    var isScrubbing = false

    @ObservationIgnored private var lastMarkAt: CFTimeInterval = -.greatestFiniteMagnitude
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?

    var duration: Double { game.durationSeconds }
    var markCount: Int { game.marks.count }
    var ticks: [Tick] {
        game.marks.map { Tick(id: $0.id, offset: $0.offsetSeconds) }
    }

    init(game: Game, context: ModelContext) {
        self.game = game
        self.context = context
        self.player = AVPlayer(url: StorageManager.gameVideoURL(for: game))
        player.defaultRate = 1

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    // MARK: Marking

    /// Places a mark at the current playhead. Returns false if debounced.
    @discardableResult
    func placeMark() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastMarkAt >= Self.debounceInterval else { return false }
        lastMarkAt = now

        let playhead = player.currentTime().seconds
        let offset = playhead.isFinite ? min(max(playhead, 0), duration) : 0
        let mark = Mark(offsetSeconds: offset)
        context.insert(mark)
        mark.game = game
        game.isProcessed = false
        try? context.save()

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
        undoExpiry?.cancel()
        undoableMark = nil
        context.delete(mark)
        game.isProcessed = game.marks.allSatisfy(\.isExtracted)
        try? context.save()
        lastMarkAt = -.greatestFiniteMagnitude
    }

    // MARK: Transport

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
        }
    }

    func jumpBack() {
        seek(to: max(0, currentTime - Self.jumpBackSeconds))
    }

    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(index + 1) % Self.speeds.count]
        player.defaultRate = speed
        if isPlaying { player.rate = speed }
    }

    func scrub(to seconds: Double) {
        isScrubbing = true
        currentTime = min(max(seconds, 0), duration)
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration)
        currentTime = target
        isScrubbing = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        undoExpiry?.cancel()
    }
}
