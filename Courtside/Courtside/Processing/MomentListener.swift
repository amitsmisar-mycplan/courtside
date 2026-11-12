import AVFoundation
import Foundation
import SoundAnalysis

enum MomentListenerError: LocalizedError {
    case noAudio
    case unreadable(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noAudio: "This video has no sound, so there's nothing to listen for."
        case .unreadable: "Courtside couldn't read this video's sound."
        }
    }
}

/// Reads a video's audio track, never its picture, and measures each second: loudness, and how
/// much cheering, applause, shouting and crowd Apple's built-in sound classifier hears
/// (decision 0029). Runs on the device, on its own queue. Keeps numbers only, never audio.
enum MomentListener {
    /// The classifier works on 16 kHz mono; asking the reader for it saves converting.
    static let sampleRate: Double = 16_000
    /// The built-in classifier's labels in each group. Checked against its list at run time.
    static let groups: [(WritableKeyPath<Groups, Float>, [String])] = [
        (\.cheering, ["cheering"]),
        (\.applause, ["applause", "clapping"]),
        (\.shouting, ["yell", "shout", "screaming", "children_shouting"]),
        (\.crowd, ["crowd"]),
    ]

    struct Groups {
        var cheering: Float = 0
        var applause: Float = 0
        var shouting: Float = 0
        var crowd: Float = 0
    }

    struct Result: Sendable {
        var signal: MomentSignal
        /// False when stopped part way; `signal` then holds the whole seconds heard so far.
        var isComplete: Bool
    }

    private static let queue = DispatchQueue(label: "Courtside.MomentListener", qos: .utility)
    /// The classifier reports a 3 s window after all of it is read, so a second is only final
    /// this long after it; a stop or checkpoint keeps the seconds before that.
    private static let settleSeconds = 4

    /// Listens to `url` from `resume.count` seconds on, adding to `resume`. `progress` gets the
    /// share of the video heard so far; `checkpoint` gets the seconds heard so far every few
    /// minutes of audio. Cancelling the task stops it within one buffer and returns what was heard.
    static func listen(
        to url: URL,
        resuming resume: MomentSignal = MomentSignal(),
        checkpointEvery checkpointSeconds: Int = 120,
        progress: @escaping @Sendable (Double) -> Void,
        checkpoint: @escaping @Sendable (MomentSignal) -> Void
    ) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack?
        let duration: Double
        do {
            track = try await asset.loadTracks(withMediaType: .audio).first
            duration = try await asset.load(.duration).seconds
        } catch {
            // Stopped before it started: nothing new heard.
            if Task.isCancelled { return Result(signal: resume, isComplete: false) }
            throw MomentListenerError.unreadable(underlying: error)
        }
        guard let loadedTrack = track else { throw MomentListenerError.noAudio }
        // Only ever used on the listening queue from here on.
        nonisolated(unsafe) let audioTrack = loadedTrack
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Swift.Result {
                        try listenNow(asset: asset, track: audioTrack, duration: duration, resume: resume,
                                      checkpointSeconds: checkpointSeconds, stop: stop,
                                      progress: progress, checkpoint: checkpoint)
                    })
                }
            }
        } onCancel: {
            stop.set()
        }
    }

    private static func listenNow(
        asset: AVAsset,
        track: AVAssetTrack,
        duration: Double,
        resume: MomentSignal,
        checkpointSeconds: Int,
        stop: StopFlag,
        progress: @Sendable (Double) -> Void,
        checkpoint: @Sendable (MomentSignal) -> Void
    ) throws -> Result {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MomentListenerError.unreadable(underlying: error)
        }
        let startSecond = resume.count
        reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(startSecond), preferredTimescale: 600), end: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MomentListenerError.unreadable(underlying: nil) }
        reader.add(output)
        guard reader.startReading() else { throw MomentListenerError.unreadable(underlying: reader.error) }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector(startSecond: startSecond)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // A 3 s window every 1.5 s: enough to catch a cheer, half the work of the default.
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: collector)
        } catch {
            throw MomentListenerError.unreadable(underlying: error)
        }

        var heard = Heard(startSecond: startSecond)
        var nextCheckpoint = startSecond + checkpointSeconds
        var lastProgress = -1.0
        let rate = Int64(sampleRate)

        while let buffer = output.copyNextSampleBuffer() {
            if stop.isSet {
                reader.cancelReading()
                // Whole, settled seconds only, so the next run starts cleanly on one.
                let signal = heard.signal(adding: resume, classes: collector, upTo: heard.currentSecond - settleSeconds)
                return Result(signal: signal, isComplete: false)
            }
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            pcm.frameLength = AVAudioFrameCount(frames)
            let samples = pcm.floatChannelData![0]
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: samples) == noErr else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let position = Int64(((time.isFinite ? time : 0) * sampleRate).rounded())
            heard.add(samples, count: frames, at: position, rate: rate)
            analyzer.analyze(pcm, atAudioFramePosition: position)

            if heard.currentSecond >= nextCheckpoint {
                nextCheckpoint = heard.currentSecond + checkpointSeconds
                checkpoint(heard.signal(adding: resume, classes: collector, upTo: heard.currentSecond - settleSeconds))
            }
            if duration > 0 {
                let share = min(1, Double(position) / sampleRate / duration)
                if share - lastProgress >= 0.005 {
                    lastProgress = share
                    progress(share)
                }
            }
        }
        if reader.status == .failed { throw MomentListenerError.unreadable(underlying: reader.error) }
        analyzer.completeAnalysis()
        progress(1)
        return Result(signal: heard.signal(adding: resume, classes: collector, upTo: nil), isComplete: true)
    }

    /// Loudness per second, from the samples read.
    private struct Heard {
        let startSecond: Int
        var sumOfSquares: [Double] = []
        var counts: [Int] = []
        /// The second the last sample read falls in: everything before it is complete.
        var currentSecond: Int

        init(startSecond: Int) {
            self.startSecond = startSecond
            currentSecond = startSecond
        }

        mutating func add(_ samples: UnsafePointer<Float>, count: Int, at position: Int64, rate: Int64) {
            for i in 0..<count {
                let second = Int((position + Int64(i)) / rate)
                let index = second - startSecond
                guard index >= 0 else { continue }
                while sumOfSquares.count <= index {
                    sumOfSquares.append(0)
                    counts.append(0)
                }
                let value = Double(samples[i])
                sumOfSquares[index] += value * value
                counts[index] += 1
                currentSecond = max(currentSecond, second)
            }
        }

        /// `resume` with the seconds heard here appended, up to (not including) `end`, or all of them.
        func signal(adding resume: MomentSignal, classes: Collector, upTo end: Int?) -> MomentSignal {
            var signal = resume
            let available = sumOfSquares.count
            let n = end.map { max(0, min(available, $0 - startSecond)) } ?? available
            let groups = classes.groups(count: n)
            for i in 0..<n {
                let mean = counts[i] > 0 ? sumOfSquares[i] / Double(counts[i]) : 0
                signal.loudness.append(Float(10 * log10(max(mean, 1e-10))))
                signal.cheering.append(groups[i].cheering)
                signal.applause.append(groups[i].applause)
                signal.shouting.append(groups[i].shouting)
                signal.crowd.append(groups[i].crowd)
            }
            return signal
        }
    }

    /// Receives the classifier's results and spreads each window's group confidences over the
    /// seconds it covers (highest wins).
    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private let startSecond: Int
        private var seconds: [Groups] = []

        init(startSecond: Int) {
            self.startSecond = startSecond
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var window = Groups()
            for (path, labels) in MomentListener.groups {
                let total = labels.reduce(Float(0)) { $0 + Float(result.classification(forIdentifier: $1)?.confidence ?? 0) }
                window[keyPath: path] = min(1, total)
            }
            let start = result.timeRange.start.seconds
            let end = start + result.timeRange.duration.seconds
            guard start.isFinite, end.isFinite else { return }
            lock.lock()
            defer { lock.unlock() }
            for second in Int(start)..<max(Int(start) + 1, Int(end.rounded(.up))) {
                let index = second - startSecond
                guard index >= 0 else { continue }
                while seconds.count <= index { seconds.append(Groups()) }
                seconds[index].cheering = max(seconds[index].cheering, window.cheering)
                seconds[index].applause = max(seconds[index].applause, window.applause)
                seconds[index].shouting = max(seconds[index].shouting, window.shouting)
                seconds[index].crowd = max(seconds[index].crowd, window.crowd)
            }
        }

        func groups(count: Int) -> [Groups] {
            lock.lock()
            defer { lock.unlock() }
            return (0..<count).map { $0 < seconds.count ? seconds[$0] : Groups() }
        }
    }

    /// Set from the cancellation handler, read by the listening loop.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// The sound labels the built-in classifier offers, for checking the groups above.
    static func availableLabels() throws -> [String] {
        try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
    }
}
