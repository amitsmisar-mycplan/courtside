#if DEBUG
import AVFoundation
import Foundation

/// Drives one clip on the tap-to-follow debug screen (decision 0027): first frame and people,
/// the tap, tracking, looping playback with the box, and the verdict.
@MainActor @Observable
final class TapToFollowSession {
    enum Phase: Equatable {
        case loading
        case choosing
        case tracking
        case review
        case failed(String)
    }

    let clipID: UUID
    let clipURL: URL
    let clipSeconds: Double

    private(set) var phase = Phase.loading
    private(set) var firstFrame: CGImage?
    private(set) var people: [CGRect] = []
    private(set) var displaySize = CGSize(width: 16, height: 9)
    private(set) var chosenBox: CGRect?
    private(set) var snappedToBody = false
    var mode: FollowMode
    private(set) var progress = 0.0
    private(set) var track: FollowTrack?
    private(set) var currentTime = 0.0
    private(set) var isPaused = false
    var scene = FollowVerdict.Scene.openCourt
    var failureNote = ""
    private(set) var savedResult: FollowVerdict.Result?
    private(set) var saveError: String?

    @ObservationIgnored let playback = LoopingClipPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private var cropCenters: [Double] = []
    @ObservationIgnored private let log: TapToFollowLog

    init(clipID: UUID, clipURL: URL, clipSeconds: Double, mode: FollowMode, log: TapToFollowLog = .standard) {
        self.clipID = clipID
        self.clipURL = clipURL
        self.clipSeconds = clipSeconds
        self.mode = mode
        self.log = log
    }

    func load() async {
        guard phase == .loading else { return }
        do {
            let frame = try await TapToFollowTracker.firstFrame(of: clipURL)
            firstFrame = frame.image
            people = frame.people
            displaySize = frame.displaySize
            phase = .choosing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// `point` is normalized to the upright first frame, origin top left.
    func tap(at point: CGPoint) {
        guard phase == .choosing else { return }
        if let body = TapToFollowTracker.snap(tap: point, to: people) {
            chosenBox = body
            snappedToBody = true
        } else {
            chosenBox = TapToFollowTracker.fallbackBox(around: point, displaySize: displaySize)
            snappedToBody = false
        }
    }

    func startTracking() {
        guard phase == .choosing, let box = chosenBox else { return }
        phase = .tracking
        progress = 0
        let url = clipURL, mode = mode
        trackingTask = Task { [weak self] in
            do {
                let track = try await TapToFollowTracker.track(url: url, from: box, mode: mode) { value in
                    Task { @MainActor in self?.progress = value }
                }
                self?.showReview(track)
            } catch is CancellationError {
                return
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func showReview(_ track: FollowTrack) {
        self.track = track
        let width = FollowCrop.windowWidth(displaySize: track.displaySize)
        cropCenters = FollowCrop.smoothedCenters(
            times: track.samples.map(\.time),
            xs: track.samples.map { Double($0.box.midX) },
            windowWidth: width
        )
        savedResult = nil
        saveError = nil
        failureNote = ""
        phase = .review
        playback.load(clipURL)
        isPaused = false
        if timeObserver == nil {
            timeObserver = playback.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds }
            }
        }
    }

    /// The tracked box for the frame on screen.
    var currentSample: FollowSample? { track?.sample(at: currentTime) }

    /// The smoothed 9:16 window for the frame on screen.
    var currentCropWindow: CGRect? {
        guard let track, !cropCenters.isEmpty else { return nil }
        let index = track.samples.lastIndex { $0.time <= currentTime } ?? 0
        return FollowCrop.window(centerX: cropCenters[index], windowWidth: FollowCrop.windowWidth(displaySize: track.displaySize))
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { playback.pause() } else { playback.player.play() }
    }

    /// Back to the first frame to tap again (e.g. with the other mode).
    func chooseAgain() {
        stopPlayback()
        track = nil
        chosenBox = nil
        phase = firstFrame == nil ? .loading : .choosing
    }

    func record(_ result: FollowVerdict.Result) {
        guard let track else { return }
        let note = failureNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = FollowVerdict(
            date: .now,
            clipID: clipID,
            result: result,
            failureNote: result == .lost && !note.isEmpty ? note : nil,
            scene: scene,
            mode: track.mode,
            processingSeconds: track.processingSeconds,
            clipSeconds: track.videoSeconds,
            videoSize: "\(Int(track.displaySize.width))x\(Int(track.displaySize.height))",
            trackedFPS: track.trackedFPS,
            framesTracked: track.samples.count,
            resnaps: track.resnaps,
            trackerRestarts: track.restarts,
            lowConfidenceFrames: track.lowConfidenceFrames,
            minConfidence: Double(track.minConfidence),
            meanConfidence: Double(track.meanConfidence),
            tapSnappedToBody: snappedToBody,
            device: TapToFollowLog.deviceName
        )
        do {
            try log.append(verdict)
            savedResult = result
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Stops tracking and playback. Call when leaving the screen.
    func stop() {
        trackingTask?.cancel()
        stopPlayback()
    }

    private func stopPlayback() {
        if let timeObserver { playback.player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playback.pause()
    }
}
#endif
