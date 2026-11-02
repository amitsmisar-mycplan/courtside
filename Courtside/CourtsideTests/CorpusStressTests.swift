import AVFoundation
import Darwin
import SwiftData
import XCTest
@testable import Courtside

/// Real-footage stress test. Skipped unless `COURTSIDE_CORPUS_DIR` names a folder of videos
/// (pass it to `xcodebuild` as `TEST_RUNNER_COURTSIDE_CORPUS_DIR`). Source videos are read only.
///
/// For each video, one at a time: import through `VideoImporter`, tap marks through
/// `MarkingSession`, undo, extract through `ClipExtractor`, check every clip, then trim, export
/// vertical and delete three of them, check for orphans, and clean up everything it created.
///
/// Optional: `COURTSIDE_CORPUS_MARKS` (marks per game, default 40), `COURTSIDE_CORPUS_FILES`
/// (comma-separated file names to run), `COURTSIDE_CORPUS_REPORT` (where to write the JSON report).
@MainActor
final class CorpusStressTests: XCTestCase {
    private static let seed: UInt64 = 2026_11_01
    private static let durationTolerance = 0.15

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testCorpus() async throws {
        guard let directory = env["COURTSIDE_CORPUS_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_CORPUS_DIR to run the real-footage stress test.")
        }
        continueAfterFailure = true
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let markCount = Int(env["COURTSIDE_CORPUS_MARKS"] ?? "") ?? 40
        let only = Set((env["COURTSIDE_CORPUS_FILES"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { ["mp4", "mov", "m4v"].contains(($0 as NSString).pathExtension.lowercased()) }
                .filter { only.isEmpty || only.contains($0) }
                .sorted()
        } catch {
            XCTFail("Can't read \(folder.path): \(error.localizedDescription). If macOS blocked it, allow the Simulator access to the folder.")
            return
        }
        XCTAssertFalse(names.isEmpty, "no videos in \(folder.path)")

        StorageManager.prepareDirectories()
        let memory = MemorySampler()
        memory.start()
        var report = CorpusReport(folder: folder.path, seed: Self.seed, marksPerGame: markCount,
                                  preRoll: ClipSettings.preRoll, postRoll: ClipSettings.postRoll)
        for (index, name) in names.enumerated() {
            var result = VideoResult(file: name)
            await run(source: folder.appendingPathComponent(name), index: index, markCount: markCount, memory: memory, into: &result)
            for failure in result.failures { XCTFail("\(name) · \(failure.step): \(failure.message)") }
            report.videos.append(result)
            writeReport(report)
        }
        memory.stop()
        report.peakMemoryMB = memory.peakMB
        writeReport(report)
        print("CORPUS REPORT\n" + report.summary)
    }

    // MARK: One video

    private func run(source: URL, index: Int, markCount: Int, memory: MemorySampler, into result: inout VideoResult) async {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Game.self, Mark.self, Clip.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            result.fail("setup", "model container: \(error)")
            return
        }
        let context = container.mainContext
        let before = FileSnapshot.take()
        var game: Game?
        memory.resetPeak()
        defer {
            // Clean up whatever happens: the game and its files, then anything else this run created.
            if let game { StorageManager.deleteGame(game, in: context) }
            let leftovers = FileSnapshot.take().added(since: before)
            leftovers.forEach(StorageManager.removeFile(at:))
            result.leftoversRemovedAtCleanup = leftovers.map(\.lastPathComponent)
            result.peakMemoryMB = memory.peakMB
        }

        // Source facts, for comparing clips against.
        let sourceAsset = AVURLAsset(url: source)
        guard let sourceTrack = try? await sourceAsset.loadTracks(withMediaType: .video).first,
              let sourceDuration = try? await sourceAsset.load(.duration).seconds,
              let sourceShown = try? await SlowMoComposer.displaySize(of: source)
        else {
            result.fail("read source", "can't read the source video")
            return
        }
        result.sourceDuration = sourceDuration
        result.sourceShown = "\(Int(sourceShown.width))x\(Int(sourceShown.height))"
        result.sourceNominalFPS = Double((try? await sourceTrack.load(.nominalFrameRate)) ?? 0)

        // a. Import.
        let progress = ProgressLog()
        let importStart = Date()
        let imported: ImportedVideo
        do {
            imported = try await VideoImporter.importFromFile(at: source) { value in progress.append(value) }
        } catch {
            result.fail("import", error.localizedDescription)
            return
        }
        result.importSeconds = Date().timeIntervalSince(importStart)
        let reports = progress.values
        result.importProgressReports = reports.count
        if reports.last != 1 { result.fail("import", "progress ended at \(reports.last ?? -1), not 1") }
        if zip(reports, reports.dropFirst()).contains(where: { $0 > $1 }) { result.fail("import", "progress went backwards") }
        if abs(imported.durationSeconds - sourceDuration) > 0.05 {
            result.fail("import", String(format: "duration %.3f s, source %.3f s", imported.durationSeconds, sourceDuration))
        }
        let copied = StorageManager.gameVideoURL(filename: imported.filename)
        if StorageManager.fileSize(at: copied) != StorageManager.fileSize(at: source) {
            result.fail("import", "copy size \(StorageManager.fileSize(at: copied)) ≠ source \(StorageManager.fileSize(at: source))")
        }
        if copied.standardizedFileURL == source.standardizedFileURL { result.fail("import", "references the source instead of copying") }
        result.importedCreatedAt = imported.createdAt.map { ISO8601DateFormatter().string(from: $0) }

        // The import screen creates the game this way (ImportFlowView); repeated here because it lives in a view.
        let newGame = Game(id: imported.gameID, label: "", recordedAt: imported.createdAt ?? .now,
                           videoFilename: imported.filename, durationSeconds: imported.durationSeconds,
                           source: .imported, videoFileSize: imported.fileSize)
        context.insert(newGame)
        try? context.save()
        game = newGame
        result.diskAfterImportMB = FileSnapshot.take().addedBytes(since: before) / 1_000_000

        // b. Marks through the tap code, then e. undo.
        var clock: CFTimeInterval = 10_000
        let session = MarkingSession(game: newGame, context: context, clock: { clock })
        let plan = MarkPlan(duration: imported.durationSeconds, count: markCount, seed: Self.seed &+ UInt64(index))
        result.plannedMarks = plan.times.count
        let markStart = Date()
        for time in plan.times {
            guard await seek(session, to: time) else {
                result.fail("marks", String(format: "couldn't seek to %.2f s", time))
                continue
            }
            if !session.placeMark() { result.fail("marks", String(format: "tap at %.2f s refused", time)) }
            clock += 2.5
        }
        // The tap's own 2-second guard: a second tap 1 s later (wall clock) must be refused.
        clock -= 1.5
        if session.placeMark() { result.fail("marks", "a tap 1 s after the previous one was accepted (2 s guard)") }
        clock += 2.5
        result.marksPlaced = newGame.marks.count
        result.markSeconds = Date().timeIntervalSince(markStart)
        result.markChecks = plan.checks(against: newGame.marks.map(\.offsetSeconds), duration: imported.durationSeconds)
        for problem in result.markChecks.problems { result.fail("marks", problem) }

        let undoTimes = plan.undoTimes
        var undoTapped: [Double] = []
        for time in undoTimes {
            _ = await seek(session, to: time)
            if session.placeMark() { undoTapped.append(newGame.marks.max { $0.createdAt < $1.createdAt }!.offsetSeconds) }
            clock += 2.5
        }
        session.undoLastMark()
        session.undoLastMark()
        session.undoLastMark()
        let undoRemaining = Set(undoTapped.prefix(2))
        let undoGone = Set(undoTapped.suffix(3))
        let offsets = newGame.marks.map(\.offsetSeconds)
        result.undoOK = undoTapped.count == 5
            && undoRemaining.allSatisfy { kept in offsets.contains { abs($0 - kept) < 0.0001 } }
            && undoGone.allSatisfy { gone in !offsets.contains { abs($0 - gone) < 0.0001 } }
            && newGame.marks.count == result.marksPlaced + 2
        if !result.undoOK { result.fail("undo", "tapped \(undoTapped.count); expected the first 2 of 5 kept and the last 3 removed") }
        session.tearDown()

        // c. Extract every clip, serially, through ClipExtractor.
        let extractor = ClipExtractor()
        let pending = newGame.pendingMarks.count
        let extractStart = Date()
        var lastCount = 0
        var lastTime = extractStart
        extractor.start(game: newGame, context: context)
        while extractor.phase == .running {
            try? await Task.sleep(for: .milliseconds(250))
            let done = extractor.completed + extractor.failed
            if done > lastCount {
                let now = Date()
                let each = now.timeIntervalSince(lastTime) / Double(done - lastCount)
                result.clipSeconds += Array(repeating: each, count: done - lastCount)
                lastCount = done
                lastTime = now
            }
            result.diskPeakMB = max(result.diskPeakMB, FileSnapshot.take().addedBytes(since: before) / 1_000_000)
        }
        result.extractSeconds = Date().timeIntervalSince(extractStart)
        result.clipsMade = extractor.completed
        result.clipsFailed = extractor.failed
        if extractor.completed != pending {
            result.fail("extract", "\(extractor.completed) of \(pending) clips made, \(extractor.failed) failed")
        }

        for clip in newGame.sortedClips {
            await check(clip, gameDuration: imported.durationSeconds, sourceShown: sourceShown, into: &result)
        }

        // Slow motion: speeds offered must follow the clip's real frame rate. The first clip (which
        // starts at the very beginning of the video) and one from mid-game.
        let clipsForSlowMo = newGame.sortedClips
        for clip in [clipsForSlowMo.first, clipsForSlowMo.dropFirst().first { ($0.markSeconds ?? 0) > imported.durationSeconds * 0.4 }].compactMap({ $0 }) {
            await checkSlowMo(clip, context: context, into: &result)
        }

        // d. Trim, vertical export and delete on three clips.
        let sorted = newGame.sortedClips
        if sorted.count >= 3 {
            var rng = SplitMix64(seed: Self.seed &+ 1000 &+ UInt64(index))
            var picks = [sorted[0], sorted[sorted.count - 1]]
            let middle = sorted[1..<(sorted.count - 1)]
            picks.insert(middle[middle.startIndex + Int(rng.next() % UInt64(middle.count))], at: 1)
            for clip in picks {
                await trimExportDelete(clip, game: newGame, context: context, before: before, into: &result)
            }
            checkOrphans(game: newGame, before: before, into: &result)
        } else {
            result.fail("trim/export/delete", "fewer than 3 clips")
        }
        result.diskPeakMB = max(result.diskPeakMB, FileSnapshot.take().addedBytes(since: before) / 1_000_000)
    }

    // MARK: Steps

    private func seek(_ session: MarkingSession, to time: Double) async -> Bool {
        session.seek(to: time)
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline {
            let now = session.player.currentTime().seconds
            if now.isFinite, abs(now - time) < 0.05 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func check(_ clip: Clip, gameDuration: Double, sourceShown: CGSize, into result: inout VideoResult) async {
        let label = String(format: "clip @%.2f s", clip.markSeconds ?? -1)
        guard StorageManager.fileExists(at: clip.fileURL) else {
            result.fail("check \(label)", "file missing")
            return
        }
        let expected = ClipWindow.around(mark: clip.markSeconds ?? 0, preRoll: ClipSettings.preRoll,
                                         postRoll: ClipSettings.postRoll, gameDuration: gameDuration)
        if abs(clip.startSeconds - expected.start) > 0.001 || abs(clip.endSeconds - expected.end) > 0.001 {
            result.fail("check \(label)", String(format: "window %.2f–%.2f, expected %.2f–%.2f", clip.startSeconds, clip.endSeconds, expected.start, expected.end))
        }
        let asset = AVURLAsset(url: clip.fileURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let error = duration - expected.duration
        result.maxDurationError = max(result.maxDurationError, abs(error))
        if abs(error) > Self.durationTolerance {
            result.fail("check \(label)", String(format: "duration %.3f s, window %.3f s", duration, expected.duration))
        }
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if video.isEmpty { result.fail("check \(label)", "no video track") }
        if audio.isEmpty { result.fail("check \(label)", "no audio track") }
        if let shown = try? await SlowMoComposer.displaySize(of: clip.fileURL),
           abs(shown.width - sourceShown.width) > 1 || abs(shown.height - sourceShown.height) > 1 {
            result.fail("check \(label)", "shown \(Int(shown.width))x\(Int(shown.height)), source \(Int(sourceShown.width))x\(Int(sourceShown.height))")
        }
        _ = await ThumbnailGenerator.thumbnail(clipID: clip.id, clipURL: clip.fileURL, clipDuration: clip.window.duration)
        if !StorageManager.fileExists(at: StorageManager.thumbnailURL(forClipID: clip.id)) {
            result.fail("check \(label)", "no thumbnail")
        }
        result.clipsChecked += 1
    }

    private func checkSlowMo(_ clip: Clip, context: ModelContext, into result: inout VideoResult) async {
        let realFPS = await RealFrameRate.measure(clip.fileURL)
        let session = SlowMoSession(clip: clip)
        await session.load()
        result.slowMo.append(SlowMoResult(
            clip: String(format: "clip @%.2f s (%.2f–%.2f s)", clip.markSeconds ?? -1, clip.startSeconds, clip.endSeconds),
            realFPS: realFPS,
            appFPS: { if case .loaded(let fps) = session.frameRate { Double(fps) } else { 0 } }(),
            offered: session.availableSpeeds.map(\.label)
        ))
        let expected = SlowMotion.availableSpeeds(frameRate: Float(realFPS))
        if session.availableSpeeds != expected {
            result.fail("slow mo", "offered \(session.availableSpeeds.map(\.label)), real \(String(format: "%.2f", realFPS)) fps allows \(expected.map(\.label))")
        }
        if realFPS < 55, session.availableSpeeds.contains(.quarter) {
            result.fail("slow mo", "0.25× offered on \(String(format: "%.2f", realFPS)) fps footage")
        }
        if realFPS >= 55 {
            let start = Date()
            let rendered = await session.render(context: context)
            result.slowMoRenderSeconds = Date().timeIntervalSince(start)
            if !rendered { result.fail("slow mo", "render failed: \(session.errorMessage ?? "?")") }
        }
        session.tearDown()
    }

    private func trimExportDelete(_ clip: Clip, game: Game, context: ModelContext, before: FileSnapshot, into result: inout VideoResult) async {
        let label = String(format: "clip @%.2f s", clip.markSeconds ?? -1)
        let filename = clip.filename
        let mark = clip.markTime
        let oldDuration = clip.window.duration

        // Trim: pull both ends out 5 s, as far as the limits allow.
        let bounds = ClipWindow.trimBounds(mark: mark, gameDuration: game.durationSeconds, current: clip.window)
        let wider = clip.window.trimming(.start, to: clip.startSeconds - 5, within: bounds)
            .trimming(.end, to: clip.endSeconds + 5, within: bounds)
        var trim = OperationResult(clip: label)
        let trimStart = Date()
        do {
            try await ClipExtractor.trim(clip, to: wider, context: context) { _ in }
            trim.seconds = Date().timeIntervalSince(trimStart)
            let duration = (try? await AVURLAsset(url: clip.fileURL).load(.duration).seconds) ?? 0
            if abs(duration - wider.duration) > Self.durationTolerance {
                result.fail("trim \(label)", String(format: "duration %.3f s, expected %.3f s", duration, wider.duration))
            }
            if clip.filename != filename { result.fail("trim \(label)", "filename changed") }
            if abs(clip.markTime - mark) > 0.0001 { result.fail("trim \(label)", "tap moved") }
            if FileManager.default.fileExists(atPath: StorageManager.partialURL(for: clip.fileURL).path) {
                result.fail("trim \(label)", "partial file left")
            }
            trim.detail = String(format: "%.1f→%.1f s", oldDuration, wider.duration)
        } catch {
            result.fail("trim \(label)", error.localizedDescription)
        }

        // Vertical export, through the same session the Save to Photos sheet uses.
        let photos = RecordingPhotos()
        let export = ClipExportSession(clipID: clip.id, source: clip.fileURL, photos: photos)
        let exportStart = Date()
        export.export(.vertical)
        await export.finish()
        trim.verticalSeconds = Date().timeIntervalSince(exportStart)
        if export.phase != .saved(.vertical) { result.fail("vertical \(label)", "ended in \(export.phase)") }
        if let saved = photos.saved.first {
            if saved.size != CGSize(width: 1080, height: 1920) { result.fail("vertical \(label)", "size \(saved.size)") }
            if !saved.hasAudio { result.fail("vertical \(label)", "no audio") }
            if abs(saved.duration - clip.window.duration) > Self.durationTolerance {
                result.fail("vertical \(label)", String(format: "duration %.3f s, clip %.3f s", saved.duration, clip.window.duration))
            }
        } else {
            result.fail("vertical \(label)", "nothing handed to Photos")
        }
        let exportsLeft = (try? FileManager.default.contentsOfDirectory(atPath: StorageManager.exportsDirectory.path))?
            .filter { $0.hasPrefix(clip.id.uuidString) } ?? []
        if !exportsLeft.isEmpty { result.fail("vertical \(label)", "temporary export left: \(exportsLeft)") }

        // Delete: the clip's file, slow mo, thumbnail and mark go.
        let files = [clip.fileURL, StorageManager.thumbnailURL(forClipID: clip.id)] + (clip.slowMoURL.map { [$0] } ?? [])
        let marksBefore = game.marks.count
        StorageManager.deleteClips([clip], in: context)
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            result.fail("delete \(label)", "\(url.lastPathComponent) still on disk")
        }
        if game.marks.count != marksBefore - 1 { result.fail("delete \(label)", "mark count \(marksBefore) → \(game.marks.count)") }
        result.operations.append(trim)
    }

    /// Every file this run added must belong to a live record.
    private func checkOrphans(game: Game, before: FileSnapshot, into result: inout VideoResult) {
        let live = Set(game.clips.flatMap { [$0.filename] + ($0.slowMoFilename.map { [$0] } ?? []) })
            .union([game.videoFilename])
            .union(game.clips.map { StorageManager.thumbnailURL(forClipID: $0.id).lastPathComponent })
        let orphans = FileSnapshot.take().added(since: before).filter { !live.contains($0.lastPathComponent) }
        result.orphans = orphans.map(\.lastPathComponent)
        if !orphans.isEmpty { result.fail("orphans", "\(orphans.count) file(s) with no record: \(result.orphans.prefix(5))") }
    }

    private func writeReport(_ report: CorpusReport) {
        let path = env["COURTSIDE_CORPUS_REPORT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("corpus-report.json").path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Mark plan

/// Where to tap, repeatable from a seed: edges, overlaps and a close pair on purpose, the rest spread out.
struct MarkPlan {
    let times: [Double]
    let undoTimes: [Double]
    private let closePair: (Double, Double)
    private let overlap: [Double]

    init(duration: Double, count: Int, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let edges = [1.0, 7.0, duration - 2.5, duration - 0.6]
        let pairAt = (duration * 0.3).rounded()
        closePair = (pairAt, pairAt + 0.6)
        let overlapAt = (duration * 0.6).rounded()
        overlap = [overlapAt, overlapAt + 5, overlapAt + 11]
        var fixed = edges + [closePair.0, closePair.1] + overlap
        // The rest, one per equal slice of the middle, at a random point in each slice.
        let remaining = max(0, count - fixed.count)
        let low = 12.0, high = duration - 15
        let slice = (high - low) / Double(max(remaining, 1))
        for i in 0..<remaining {
            fixed.append(low + slice * (Double(i) + 0.1 + 0.8 * rng.unit()))
        }
        times = fixed.filter { $0 >= 0 && $0 <= duration }.sorted()
        // Five more for the undo check, away from the others.
        undoTimes = (0..<5).map { duration * 0.45 + Double($0) * 1.3 }
    }

    struct Checks: Codable {
        var inFirst10s = 0
        var inLast3s = 0
        var pairsUnder13s = 0
        var pairsUnder1s = 0
        var spanCovered = 0.0
        var problems: [String] = []
    }

    func checks(against marks: [Double], duration: Double) -> Checks {
        var checks = Checks()
        let sorted = marks.sorted()
        checks.inFirst10s = sorted.filter { $0 < 10 }.count
        checks.inLast3s = sorted.filter { $0 > duration - 3 }.count
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if b - a < 13 { checks.pairsUnder13s += 1 }
            if b - a < 1 { checks.pairsUnder1s += 1 }
        }
        checks.spanCovered = ((sorted.last ?? 0) - (sorted.first ?? 0)) / max(duration, 1)
        if checks.inFirst10s < 2 { checks.problems.append("fewer than 2 marks in the first 10 s") }
        if checks.inLast3s < 2 { checks.problems.append("fewer than 2 marks in the last 3 s") }
        if checks.pairsUnder1s < 1 { checks.problems.append("no two marks within 1 s") }
        if checks.pairsUnder13s < 1 { checks.problems.append("no overlapping windows") }
        if sorted.count != times.count { checks.problems.append("\(sorted.count) marks stored, \(times.count) planned") }
        for (stored, planned) in zip(sorted, times) where abs(stored - planned) > 0.05 {
            checks.problems.append(String(format: "mark at %.3f s, planned %.3f s", stored, planned))
        }
        return checks
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Measuring

/// Frames ÷ duration, from frame timestamps (no decoding). Doesn't trust `nominalFrameRate`.
enum RealFrameRate {
    static func measure(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange),
              let reader = try? AVAssetReader(asset: asset)
        else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        return range.duration.seconds > 0 ? Double(frames) / range.duration.seconds : 0
    }
}

/// Samples this process's memory footprint every half second and keeps the peak.
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?

    var peakMB: Double { lock.withLock { Double(peak) / 1_000_000 } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func resetPeak() { lock.withLock { peak = 0 }; sample() }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        lock.withLock { peak = max(peak, info.phys_footprint) }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// The app's storage folders, to find exactly the files a run added (never touching anything older).
struct FileSnapshot {
    let files: [URL: Int64]

    static func take() -> FileSnapshot {
        var files: [URL: Int64] = [:]
        for directory in [StorageManager.gamesDirectory, StorageManager.clipsDirectory,
                          StorageManager.thumbnailsDirectory, StorageManager.exportsDirectory] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls {
                files[url.standardizedFileURL] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return FileSnapshot(files: files)
    }

    func added(since earlier: FileSnapshot) -> [URL] {
        files.keys.filter { earlier.files[$0] == nil }.sorted { $0.path < $1.path }
    }

    func addedBytes(since earlier: FileSnapshot) -> Double {
        Double(added(since: earlier).reduce(Int64(0)) { $0 + (files[$1] ?? 0) })
    }
}

/// Stands in for Photos: records what would be saved, measured while the file still exists.
private final class RecordingPhotos: PhotoLibrarySaving, @unchecked Sendable {
    struct Saved {
        let size: CGSize
        let duration: Double
        let hasAudio: Bool
    }
    var saved: [Saved] = []

    func requestAddAccess() async -> PhotoAccess { .granted }

    func saveVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let size = (try? await SlowMoComposer.displaySize(of: url)) ?? .zero
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        saved.append(Saved(size: size, duration: duration, hasAudio: !audio.isEmpty))
    }
}

// MARK: - Report

struct Failure: Codable {
    let step: String
    let message: String
}

struct SlowMoResult: Codable {
    let clip: String
    /// Frames ÷ duration.
    let realFPS: Double
    /// What the app read (the clip track's nominal frame rate).
    let appFPS: Double
    let offered: [String]
}

struct OperationResult: Codable {
    let clip: String
    var detail = ""
    var seconds = 0.0
    var verticalSeconds = 0.0
}

struct VideoResult: Codable {
    let file: String
    var sourceDuration = 0.0
    var sourceShown = ""
    var sourceNominalFPS = 0.0
    var importSeconds = 0.0
    var importProgressReports = 0
    var importedCreatedAt: String?
    var plannedMarks = 0
    var marksPlaced = 0
    var markSeconds = 0.0
    var markChecks = MarkPlan.Checks()
    var undoOK = false
    var extractSeconds = 0.0
    var clipSeconds: [Double] = []
    var clipsMade = 0
    var clipsFailed = 0
    var clipsChecked = 0
    var maxDurationError = 0.0
    var slowMo: [SlowMoResult] = []
    var slowMoRenderSeconds: Double?
    var operations: [OperationResult] = []
    var orphans: [String] = []
    var leftoversRemovedAtCleanup: [String] = []
    var diskAfterImportMB = 0.0
    var diskPeakMB = 0.0
    var peakMemoryMB = 0.0
    var failures: [Failure] = []

    mutating func fail(_ step: String, _ message: String) {
        failures.append(Failure(step: step, message: message))
    }
}

struct CorpusReport: Codable {
    let folder: String
    let seed: UInt64
    let marksPerGame: Int
    let preRoll: Double
    let postRoll: Double
    var videos: [VideoResult] = []
    var peakMemoryMB = 0.0

    var summary: String {
        videos.map { video in
            let slowest = video.clipSeconds.max() ?? 0
            return String(format: "%@: import %.1fs, %d/%d clips in %.0fs (slowest %.1fs), %d failures",
                          video.file, video.importSeconds, video.clipsMade, video.plannedMarks + 2,
                          video.extractSeconds, slowest, video.failures.count)
        }.joined(separator: "\n")
    }
}
