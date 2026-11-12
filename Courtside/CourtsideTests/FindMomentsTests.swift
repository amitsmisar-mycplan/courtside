import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// The schema as it was before "Find Moments" (decision 0029), to build an old store.
private enum BeforeMoments {
    @Model final class Game {
        var id: UUID
        var label: String
        var recordedAt: Date
        var source: GameSource
        var isProcessed: Bool
        var keepsVideo: Bool = false
        var opponent: String?
        var ourScore: Int?
        var theirScore: Int?
        var notes: String?
        var team: String?
        var tournament: String?
        @Relationship(deleteRule: .cascade, inverse: \Mark.game) var marks: [Mark]
        @Relationship(deleteRule: .cascade, inverse: \Clip.game) var clips: [Clip]
        @Relationship(deleteRule: .cascade, inverse: \GamePart.game) var parts: [GamePart] = []
        var videoFilename: String
        var durationSeconds: Double
        var videoFileSize: Int64
        var isVideoAvailable: Bool
        var processedAt: Date?

        init(id: UUID) {
            self.id = id
            label = "Old game"
            recordedAt = .now
            source = .recorded
            isProcessed = true
            videoFilename = "old.mov"
            durationSeconds = 600
            videoFileSize = 1
            isVideoAvailable = true
            opponent = "Hawks"
            marks = []
            clips = []
        }
    }

    @Model final class GamePart {
        var id: UUID
        var index: Int
        var videoFilename: String
        var durationSeconds: Double
        var videoFileSize: Int64
        var recordedAt: Date
        var isVideoAvailable: Bool
        var processedAt: Date?
        var game: Game?
        @Relationship(deleteRule: .nullify, inverse: \Mark.part) var marks: [Mark]
        @Relationship(deleteRule: .nullify, inverse: \Clip.part) var clips: [Clip]

        init(id: UUID) {
            self.id = id
            index = 0
            videoFilename = "old.mov"
            durationSeconds = 600
            videoFileSize = 1
            recordedAt = .now
            isVideoAvailable = true
            marks = []
            clips = []
        }
    }

    @Model final class Mark {
        var id: UUID
        var offsetSeconds: Double
        var createdAt: Date
        var isExtracted: Bool
        var game: Game?
        var part: GamePart?

        init() {
            id = UUID()
            offsetSeconds = 120
            createdAt = .now
            isExtracted = true
        }
    }

    @Model final class Clip {
        var id: UUID
        var filename: String
        var startSeconds: Double
        var endSeconds: Double
        var createdAt: Date
        var fileSize: Int64
        var markSeconds: Double?
        var slowMoFilename: String?
        var slowMoSpeed: Double?
        var slowMoStartSeconds: Double?
        var slowMoEndSeconds: Double?
        var slowMoFileSize: Int64?
        var aimTrackData: Data?
        var game: Game?
        var part: GamePart?

        init() {
            id = UUID()
            filename = "old-clip.mov"
            startSeconds = 110
            endSeconds = 123
            createdAt = .now
            fileSize = 1
            markSeconds = 120
        }
    }
}

/// Synthetic per-second signals for the peak picker: a steady crowd with small, repeatable
/// wobble, and bumps where the crowd reacts.
private struct Synthetic {
    var reaction: [Double]
    var loudness: [Double]

    init(seconds: Int, reactionFloor: Double = 0.03, loudnessFloor: Double = -22) {
        // A fixed, irregular wobble: the noise floor is never perfectly flat.
        reaction = (0..<seconds).map { reactionFloor + 0.01 * Double(($0 * 7919) % 11) / 10 }
        loudness = (0..<seconds).map { loudnessFloor + 0.6 * Double(($0 * 104_729) % 13) / 12 }
    }

    /// A cheer: `height` more reaction and `louder` dB, rising and falling over `length` seconds.
    mutating func cheer(at second: Int, height: Double = 0.25, louder: Double = 2, length: Int = 5) {
        for offset in 0..<length where second + offset < reaction.count {
            let shape = sin(Double(offset + 1) / Double(length + 1) * .pi)
            reaction[second + offset] += height * shape
            loudness[second + offset] += louder * shape
        }
    }

    func pick(avoiding marks: [Double] = [], settings: MomentPicker.Settings = MomentPicker.Settings()) -> [MomentPicker.Candidate] {
        MomentPicker.pick(reaction: reaction, loudness: loudness, avoiding: marks, settings: settings)
    }
}

/// "Find Moments" (decision 0029): peak picking, storage and migration, accept / dismiss, cleanup,
/// and a real scan of a generated soundtrack that stops and resumes.
@MainActor
final class FindMomentsTests: XCTestCase {
    private var files: [URL] = []

    override func setUp() async throws {
        StorageManager.prepareDirectories()
    }

    override func tearDown() async throws {
        files.forEach(StorageManager.removeFile(at:))
    }

    private func times(_ candidates: [MomentPicker.Candidate]) -> [Double] {
        candidates.map(\.seconds)
    }

    private func assertNear(_ found: [Double], _ expected: [Double], within tolerance: Double = 3,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.count, expected.count, "found \(found)", file: file, line: line)
        for (a, b) in zip(found, expected) {
            XCTAssertEqual(a, b, accuracy: tolerance, "found \(found)", file: file, line: line)
        }
    }

    /// The two strongest suggestions are the bursts; anything else (one per 3 minutes is allowed) is weaker.
    private func assertStrongest(_ moments: [SuggestedMoment], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let top = moments.sorted { $0.score > $1.score }.prefix(expected.count).map(\.seconds).sorted()
        assertNear(top, expected, file: file, line: line)
    }

    // MARK: Peak picking

    func testSteadyCrowdSuggestsNothing() {
        XCTAssertEqual(Synthetic(seconds: 900).pick(), [], "no moment stands out of a steady gym")
        XCTAssertEqual(MomentPicker.pick(reaction: Array(repeating: 0, count: 600), loudness: Array(repeating: -60, count: 600), avoiding: []), [])
        XCTAssertEqual(MomentPicker.pick(reaction: [], loudness: [], avoiding: []), [])
    }

    func testFindsEachCheerAtItsPeak() {
        var signal = Synthetic(seconds: 900)
        for second in [100, 260, 500, 780] { signal.cheer(at: second) }
        // A 5-second cheer peaks in its third second.
        assertNear(times(signal.pick()), [102, 262, 502, 782], within: 1)
    }

    func testSuggestionsAreAtLeastTwentySecondsApart() {
        var close = Synthetic(seconds: 600)
        close.cheer(at: 200, height: 0.2)
        close.cheer(at: 212, height: 0.35)
        assertNear(times(close.pick()), [214], within: 1)
        XCTAssertEqual(close.pick().count, 1, "two cheers 12 s apart are one suggestion: the louder one")

        var apart = Synthetic(seconds: 600)
        apart.cheer(at: 200)
        apart.cheer(at: 225)
        XCTAssertEqual(apart.pick().count, 2, "25 s apart, both")
    }

    func testSkipsMomentsWithinAClipWindowOfAMark() {
        var signal = Synthetic(seconds: 600)
        signal.cheer(at: 100)
        signal.cheer(at: 300)
        // 102 is 8 s from a mark at 110: already a clip there. 302 is 20 s from one at 322: kept.
        assertNear(times(signal.pick(avoiding: [110, 322])), [302], within: 1)
        // 13 s is the default window, 10 before + 3 after.
        XCTAssertEqual(signal.pick(avoiding: [102 + 12.9]).count, 1)
        XCTAssertEqual(signal.pick(avoiding: [102 + 13]).count, 2)
    }

    func testThresholdFollowsEachVideosOwnNoiseFloor() {
        // A loud, echoey gym: a crowd floor ten times higher and much louder. The same-sized
        // reaction still stands out against its own floor.
        var loud = Synthetic(seconds: 900, reactionFloor: 0.3, loudnessFloor: -12)
        loud.cheer(at: 400)
        assertNear(times(loud.pick()), [402], within: 1)

        // The crowd fills up halfway through and stays louder. The step is not a stream of
        // suggestions: the floor catches up, and a cheer on top of the louder half is still found.
        var filling = Synthetic(seconds: 1200)
        for second in 600..<1200 {
            filling.reaction[second] += 0.15
            filling.loudness[second] += 4
        }
        filling.cheer(at: 300)
        filling.cheer(at: 900)
        let found = times(filling.pick())
        XCTAssertTrue(found.contains { abs($0 - 302) <= 1 }, "\(found)")
        XCTAssertTrue(found.contains { abs($0 - 902) <= 1 }, "\(found)")
        XCTAssertLessThanOrEqual(found.filter { abs($0 - 600) <= 60 }.count, 1, "at most one around the step: \(found)")
        XCTAssertEqual(found.count, found.filter { abs($0 - 302) <= 1 || abs($0 - 902) <= 1 || abs($0 - 600) <= 60 }.count)

        // A small wobble in a quiet video is not a moment, even though nothing else is louder.
        var quiet = Synthetic(seconds: 900)
        quiet.cheer(at: 400, height: 0.005, louder: 0.2)
        XCTAssertEqual(quiet.pick(), [])
    }

    func testLoudnessAloneStillFindsMomentsAndBreaksTies() {
        // The classifier hears nothing crowd-like: loudness carries it.
        var silentClassifier = Synthetic(seconds: 600)
        silentClassifier.reaction = Array(repeating: 0, count: 600)
        silentClassifier.cheer(at: 150, height: 0, louder: 9)
        silentClassifier.cheer(at: 450, height: 0, louder: 9)
        assertNear(times(silentClassifier.pick()), [152, 452], within: 1)

        // Two equal cheers 10 s apart: the louder one wins.
        var tie = Synthetic(seconds: 600)
        tie.cheer(at: 200, height: 0.25, louder: 1)
        tie.cheer(at: 210, height: 0.25, louder: 4)
        assertNear(times(tie.pick()), [212], within: 1)
    }

    func testListIsCappedPerHourStrongestFirst() {
        var signal = Synthetic(seconds: 3600)
        // A cheer every 40 s, growing stronger through the game: 89 of them.
        for (index, second) in stride(from: 40, to: 3580, by: 40).enumerated() {
            signal.cheer(at: second, height: 0.15 + 0.004 * Double(index))
        }
        let found = signal.pick()
        XCTAssertEqual(found.count, 20, "20 per hour")
        XCTAssertGreaterThan(found.map(\.seconds).min() ?? 0, 2600, "the strongest are kept")
        XCTAssertEqual(found.map(\.seconds), found.map(\.seconds).sorted(), "in time order")

        // One per started 3 minutes: a 5-minute video gets 2, a 1-minute video 1.
        var short = Synthetic(seconds: 300)
        for second in [40, 100, 160, 220] { short.cheer(at: second) }
        XCTAssertEqual(short.pick().count, 2)
        var minute = Synthetic(seconds: 60)
        minute.cheer(at: 10)
        minute.cheer(at: 40)
        XCTAssertEqual(minute.pick().count, 1)
    }

    func testEachSuggestionSaysWhatItHeard() {
        var signal = MomentSignal()
        for second in 0..<300 {
            signal.loudness.append(-22 + Float(second % 5) * 0.1)
            signal.cheering.append(0.01)
            signal.applause.append(0)
            signal.shouting.append(0.005 * Float(second % 3))
            signal.crowd.append(0.01)
        }
        for second in 100..<105 { signal.cheering[second] = 0.3 }
        for second in 200..<205 { signal.applause[second] = 0.3 }
        let found = MomentPicker.pick(signal, avoiding: [])
        XCTAssertEqual(found.map(\.sound), [.cheering, .applause])
        XCTAssertEqual(signal.sound(at: 50), .loud, "nothing crowd-like")
        XCTAssertEqual(signal.prefix(120).count, 120)
    }

    // MARK: Storage and migration

    func testStoreFromBeforeMomentsOpensAndDeletingTheGameRemovesSuggestions() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("moments-migrate-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix)) }
        }
        let gameID = UUID(), partID = UUID()
        do {
            let old = try ModelContainer(
                for: Schema([BeforeMoments.Game.self, BeforeMoments.GamePart.self, BeforeMoments.Mark.self, BeforeMoments.Clip.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let game = BeforeMoments.Game(id: gameID)
            old.mainContext.insert(game)
            let part = BeforeMoments.GamePart(id: partID)
            old.mainContext.insert(part)
            part.game = game
            let mark = BeforeMoments.Mark()
            old.mainContext.insert(mark)
            mark.game = game
            mark.part = part
            let clip = BeforeMoments.Clip()
            old.mainContext.insert(clip)
            clip.game = game
            clip.part = part
            try old.mainContext.save()
        }

        do {
            // Today's app: lightweight migration adds the new model and the empty field.
            let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self,
                                               configurations: ModelConfiguration(url: storeURL))
            let context = container.mainContext
            let game = try XCTUnwrap(try context.fetch(FetchDescriptor<Game>()).first { $0.id == gameID })
            let part = try XCTUnwrap(game.parts.first)
            XCTAssertEqual(part.id, partID)
            XCTAssertNil(part.momentsFoundAt)
            XCTAssertTrue(part.suggestions.isEmpty)
            XCTAssertEqual(game.opponent, "Hawks")
            XCTAssertEqual(game.marks.map(\.offsetSeconds), [120])
            XCTAssertEqual(game.clips.first?.window, ClipWindow(start: 110, end: 123))

            MomentFinder.save([.init(seconds: 300, score: 4, sound: .cheering), .init(seconds: 450, score: 3, sound: .loud)],
                              to: part, spacing: 20, context: context)
        }

        let reopened = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self,
                                          configurations: ModelConfiguration(url: storeURL))
        let context = reopened.mainContext
        let game = try XCTUnwrap(try context.fetch(FetchDescriptor<Game>()).first)
        let part = try XCTUnwrap(game.parts.first)
        XCTAssertEqual(part.orderedSuggestions.map(\.seconds), [300, 450])
        XCTAssertEqual(part.orderedSuggestions.map(\.sound), [.cheering, .loud])
        XCTAssertEqual(part.orderedSuggestions.map(\.status), [.pending, .pending])
        XCTAssertNotNil(part.momentsFoundAt)

        StorageManager.deleteGame(game, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SuggestedMoment>()).isEmpty, "the game's suggestions go with it")
        XCTAssertTrue(try context.fetch(FetchDescriptor<GamePart>()).isEmpty)
    }

    /// An in-memory game with one part (no video file needed unless a test writes one).
    private func makeGame(duration: Double = 600) throws -> (ModelContainer, Game, GamePart) {
        let container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let id = UUID()
        let game = Game(label: "", recordedAt: .now, videoFilename: StorageManager.makeGameVideoFilename(id: id, fileExtension: "m4a"),
                        durationSeconds: duration, source: .imported, videoFileSize: 1)
        container.mainContext.insert(game)
        try container.mainContext.save()
        return (container, game, try XCTUnwrap(game.parts.first))
    }

    func testAcceptMakesAnOrdinaryMarkAndUndoRemovesIt() throws {
        let (container, game, part) = try makeGame()
        let context = container.mainContext
        game.isProcessed = true
        MomentFinder.save([.init(seconds: 95, score: 5, sound: .cheering), .init(seconds: 300, score: 3, sound: .applause)],
                          to: part, spacing: 20, context: context)
        let (first, second) = (part.orderedSuggestions[0], part.orderedSuggestions[1])

        let mark = try XCTUnwrap(first.accept(in: context))
        XCTAssertEqual(mark.offsetSeconds, 95)
        XCTAssertTrue(mark.part === part)
        XCTAssertFalse(mark.isExtracted)
        XCTAssertEqual(game.extractableMarks.map(\.id), [mark.id], "the normal clip pipeline picks it up")
        XCTAssertFalse(game.isProcessed)
        XCTAssertEqual(first.status, .accepted)
        XCTAssertNil(first.accept(in: context), "accepting twice adds nothing")
        XCTAssertEqual(game.marks.count, 1)
        XCTAssertEqual(game.clips.count, 0, "a suggestion never becomes a clip by itself")
        // The clip it gets is the default window, 10 s before and 3 s after.
        XCTAssertEqual(ClipWindow.around(mark: mark.offsetSeconds, preRoll: ClipWindow.defaultPreRoll,
                                         postRoll: ClipWindow.defaultPostRoll, gameDuration: part.durationSeconds),
                       ClipWindow(start: 85, end: 98))

        second.dismiss(in: context)
        XCTAssertEqual(second.status, .dismissed)
        XCTAssertNil(second.accept(in: context), "a dismissed moment isn't accepted by a stray tap")
        XCTAssertEqual(game.marks.count, 1)

        first.undo(in: context)
        XCTAssertEqual(first.status, .pending)
        XCTAssertTrue(game.marks.isEmpty, "undo removes the mark Accept made")
        XCTAssertTrue(game.isProcessed)
        second.undo(in: context)
        XCTAssertEqual(second.status, .pending)

        // Once its clip is made, the mark stays: undo is no longer offered.
        let kept = try XCTUnwrap(first.accept(in: context))
        kept.isExtracted = true
        XCTAssertFalse(first.canUndo)
        first.undo(in: context)
        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(game.marks.count, 1)

        // No mark on a part whose video is gone.
        part.isVideoAvailable = false
        XCTAssertNil(second.accept(in: context))
    }

    func testFindingAgainKeepsDecisionsAndReplacesPending() throws {
        let (container, _, part) = try makeGame()
        let context = container.mainContext
        MomentFinder.save([.init(seconds: 100, score: 5, sound: .cheering), .init(seconds: 200, score: 4, sound: .cheering),
                           .init(seconds: 300, score: 3, sound: .crowd)], to: part, spacing: 20, context: context)
        let byTime = Dictionary(uniqueKeysWithValues: part.suggestions.map { ($0.seconds, $0) })
        byTime[100]!.accept(in: context)
        byTime[200]!.dismiss(in: context)

        let added = MomentFinder.save([.init(seconds: 105, score: 5, sound: .cheering), .init(seconds: 210, score: 4, sound: .cheering),
                                       .init(seconds: 400, score: 3, sound: .applause)], to: part, spacing: 20, context: context)
        XCTAssertEqual(added, 1, "nothing new next to a moment already accepted or dismissed")
        XCTAssertEqual(part.orderedSuggestions.map(\.seconds), [100, 200, 400])
        XCTAssertEqual(part.orderedSuggestions.map(\.status), [.accepted, .dismissed, .pending])
    }

    func testDeletingAPartsVideoRemovesItsSuggestionsAndScan() throws {
        let (container, game, part) = try makeGame()
        let context = container.mainContext
        MomentFinder.save([.init(seconds: 100, score: 5, sound: .cheering)], to: part, spacing: 20, context: context)
        var scan = MomentSignal()
        scan.loudness = [-20]; scan.cheering = [0]; scan.applause = [0]; scan.shouting = [0]; scan.crowd = [0]
        StorageManager.saveMomentScan(scan, forPartID: part.id)
        files.append(StorageManager.momentScanURL(forPartID: part.id))
        XCTAssertEqual(StorageManager.loadMomentScan(forPartID: part.id), scan)

        StorageManager.deleteGameVideo(game, in: context)
        XCTAssertTrue(part.suggestions.isEmpty)
        XCTAssertNil(part.momentsFoundAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SuggestedMoment>()).isEmpty)
        XCTAssertNil(StorageManager.loadMomentScan(forPartID: part.id), "the saved scan goes too")
        XCTAssertEqual(game.marks.count, 0)
    }

    // MARK: Listening to a real file

    /// A soundtrack of quiet crowd murmur with loud bursts at `bursts` seconds, 4 s each.
    private func writeSoundtrack(to url: URL, seconds: Int, bursts: [Int]) throws {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        var generator = SeededGenerator()
        for second in 0..<seconds {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            buffer.frameLength = AVAudioFrameCount(rate)
            let loud = bursts.contains { second >= $0 && second < $0 + 4 }
            let amplitude: Float = loud ? 0.6 : 0.03
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(rate) { samples[i] = amplitude * Float.random(in: -1...1, using: &generator) }
            try file.write(from: buffer)
        }
    }

    func testListensToARealFileStopsAndResumes() async throws {
        let (container, game, part) = try makeGame(duration: 400)
        let url = StorageManager.videoURL(for: part)
        files.append(url)
        files.append(StorageManager.momentScanURL(forPartID: part.id))
        try writeSoundtrack(to: url, seconds: 400, bursts: [40, 95])
        XCTAssertTrue(try MomentListener.availableLabels().contains("cheering"))

        // The whole file in one go.
        let whole = try await MomentListener.listen(to: url, progress: { _ in }, checkpoint: { _ in })
        XCTAssertTrue(whole.isComplete)
        XCTAssertEqual(whole.signal.count, 400, accuracy: 1)
        XCTAssertGreaterThan(whole.signal.loudness[41], whole.signal.loudness[20] + 15, "the burst is much louder")

        // Stopped part way: whole seconds heard so far come back; the rest is read on resume.
        let handle = TaskHandle()
        let stopped = Task { () -> MomentListener.Result in
            try await MomentListener.listen(to: url, checkpointEvery: 30, progress: { share in
                if share > 0.3 { handle.cancel() }
            }, checkpoint: { _ in })
        }
        handle.task = stopped
        let partial = try await stopped.value
        XCTAssertFalse(partial.isComplete)
        XCTAssertLessThan(partial.signal.count, whole.signal.count)
        let resumeFrom = whole.signal.prefix(70)
        let resumed = try await MomentListener.listen(to: url, resuming: resumeFrom, progress: { _ in }, checkpoint: { _ in })
        XCTAssertTrue(resumed.isComplete)
        XCTAssertEqual(resumed.signal.count, whole.signal.count)
        for second in 72..<(whole.signal.count - 1) {
            XCTAssertEqual(resumed.signal.loudness[second], whole.signal.loudness[second], accuracy: 0.5, "second \(second)")
        }

        // Through the finder, the way the screen runs it: suggestions are saved for review.
        let finder = MomentFinder()
        XCTAssertTrue(finder.start(part: part, context: container.mainContext))
        XCTAssertFalse(MomentFinder().start(part: part, context: container.mainContext), "one scan at a time")
        await finder.waitUntilDone()
        XCTAssertEqual(finder.phase, .finished)
        assertStrongest(part.orderedSuggestions, [42, 97])
        XCTAssertEqual(finder.found, part.suggestions.count)
        XCTAssertNil(StorageManager.loadMomentScan(forPartID: part.id), "nothing saved once it's finished")
        XCTAssertTrue(game.marks.isEmpty, "suggestions only")
    }

    func testBackgroundTimeRunningOutPausesAndResumesFromTheSavedScan() async throws {
        let (container, _, part) = try makeGame(duration: 400)
        let url = StorageManager.videoURL(for: part)
        files.append(url)
        files.append(StorageManager.momentScanURL(forPartID: part.id))
        try writeSoundtrack(to: url, seconds: 400, bursts: [40, 95])

        let background = ExpiringBackgroundTime()
        let finder = MomentFinder(backgroundTime: background)
        XCTAssertTrue(finder.start(part: part, context: container.mainContext))
        background.expire()
        await finder.waitUntilDone()
        XCTAssertEqual(finder.phase, .interrupted)
        XCTAssertEqual(background.ended.count, 1, "background time handed back at once")
        XCTAssertNotNil(StorageManager.loadMomentScan(forPartID: part.id), "what it heard is saved")
        XCTAssertTrue(part.suggestions.isEmpty)

        XCTAssertTrue(finder.start(part: part, context: container.mainContext))
        await finder.waitUntilDone()
        XCTAssertEqual(finder.phase, .finished)
        assertStrongest(part.orderedSuggestions, [42, 97])
        XCTAssertNil(StorageManager.loadMomentScan(forPartID: part.id))
    }

    func testVideoWithoutSoundSaysSo() async throws {
        let (container, _, part) = try makeGame(duration: 2)
        part.videoFilename = StorageManager.makeGameVideoFilename(id: UUID(), fileExtension: "mov")
        let url = StorageManager.videoURL(for: part)
        files.append(url)
        try await TestMedia.makeVideo(at: url, seconds: 2, fps: 10, withTone: false)
        let finder = MomentFinder()
        finder.start(part: part, context: container.mainContext)
        await finder.waitUntilDone()
        XCTAssertEqual(finder.phase, .failed(MomentListenerError.noAudio.errorDescription!))
        XCTAssertNil(part.momentsFoundAt)
    }
}

/// Repeatable noise, so a scan test hears the same soundtrack every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Lets a listener's progress callback stop its own task part way.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<MomentListener.Result, Error>?
    private var cancelled = false

    var task: Task<MomentListener.Result, Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue; if cancelled { newValue?.cancel() } } }
    }

    func cancel() {
        lock.withLock { cancelled = true; stored?.cancel() }
    }
}

/// Background time that iOS takes back on demand.
@MainActor
private final class ExpiringBackgroundTime: BackgroundTimeGranting {
    private var onExpiry: (@MainActor () -> Void)?
    private(set) var ended: [UIBackgroundTaskIdentifier] = []

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        self.onExpiry = onExpiry
        return UIBackgroundTaskIdentifier(rawValue: 1)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        ended.append(task)
    }

    func expire() {
        onExpiry?()
    }
}
