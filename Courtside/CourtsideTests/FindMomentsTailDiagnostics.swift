import XCTest
@testable import Courtside

/// Why a long game's last minutes got no Find Moments suggestions (investigation, no behavior
/// change; see docs/investigations/find-moments-tail.md). Skipped unless
/// `COURTSIDE_MOMENTS_DIAG` names a JSON file:
/// `{"video": path, "out": folder, "marks": [seconds], "found": [seconds of the existing suggestions]}`.
/// Listens to the video once (the numbers are cached in `out` as `signal.json`; no audio is kept),
/// then writes `diagnostics.txt`: the threshold, the cap, per-minute counts of seconds above the
/// threshold, the best score, and why each peak was dropped (per-hour cap, spacing, mark
/// clearance), plus three alternative pickers compared on the same numbers. The video is only read.
final class FindMomentsTailDiagnostics: XCTestCase {
    private struct Config: Decodable {
        var video: String
        var out: String
        var marks: [Double]
        var found: [Double]
    }

    private enum Fate: String {
        case chosen, cap, spacing, marks
    }

    /// The picker's scoring, step for step (`MomentPicker.pick(reaction:loudness:...)`), kept here so
    /// the app's code is unchanged.
    private struct Scored {
        var score: [Double]
        var loudnessLift: [Double]
        var threshold: Double
        var typical: Double
        var spread: Double
    }

    private func scored(_ signal: MomentSignal, settings: MomentPicker.Settings) -> Scored {
        let reaction = signal.reaction, loudness = signal.loudness.map(Double.init)
        let n = min(reaction.count, loudness.count)
        let reactionLift = MomentPicker.lift(reaction, halfWindow: settings.floorHalfWindow,
                                             minimumSpread: MomentPicker.Settings.minimumReactionSpread)
        let loudnessLift = MomentPicker.lift(loudness, halfWindow: settings.floorHalfWindow,
                                             minimumSpread: MomentPicker.Settings.minimumLoudnessSpread)
        let raw = (0..<n).map { settings.reactionWeight * reactionLift[$0] + settings.loudnessWeight * loudnessLift[$0] }
        let score = (0..<n).map { i in
            let window = raw[max(0, i - 1)...min(n - 1, i + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
        let typical = MomentPicker.median(score)
        let spread = MomentPicker.spread(score)
        let threshold = max(settings.minimumScore, typical + settings.spreads * max(spread, 0.25))
        return Scored(score: score, loudnessLift: loudnessLift, threshold: threshold, typical: typical, spread: spread)
    }

    /// Local peaks at or above `threshold(i)`, strongest first, as the picker orders them.
    private func peaks(_ s: Scored, threshold: (Int) -> Double) -> [Int] {
        let score = s.score, n = score.count
        var peaks: [Int] = []
        for i in 0..<n where score[i] >= threshold(i) {
            let left = i > 0 ? score[i - 1] : -.infinity
            let right = i < n - 1 ? score[i + 1] : -.infinity
            if score[i] > left && score[i] >= right { peaks.append(i) }
        }
        return peaks.sorted { a, b in
            if score[a] != score[b] { return score[a] > score[b] }
            if s.loudnessLift[a] != s.loudnessLift[b] { return s.loudnessLift[a] > s.loudnessLift[b] }
            return a < b
        }
    }

    /// The picker's selection loop, recording why each peak was or wasn't kept.
    private func select(_ peaks: [Int], limit: Int, marks: [Double], settings: MomentPicker.Settings,
                        preset: [Int] = []) -> (chosen: [Int], fate: [Int: Fate]) {
        var chosen = preset
        var fate: [Int: Fate] = [:]
        for i in preset { fate[i] = .chosen }
        for i in peaks where fate[i] == nil {
            let seconds = Double(i)
            if chosen.count >= limit { fate[i] = .cap; continue }
            if marks.contains(where: { abs($0 - seconds) < settings.markClearance }) { fate[i] = .marks; continue }
            if chosen.contains(where: { abs(Double($0) - seconds) < settings.spacing }) { fate[i] = .spacing; continue }
            chosen.append(i)
            fate[i] = .chosen
        }
        return (chosen.sorted(), fate)
    }

    private func limit(_ n: Int, _ settings: MomentPicker.Settings) -> Int {
        max(settings.minimumCount, Int((Double(n) / 3600 * settings.perHour).rounded(.up)))
    }

    func testWhyTheTailGotNoSuggestions() async throws {
        guard let path = ProcessInfo.processInfo.environment["COURTSIDE_MOMENTS_DIAG"] else {
            throw XCTSkip("Set TEST_RUNNER_COURTSIDE_MOMENTS_DIAG to diagnose Find Moments on a real video.")
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let out = URL(fileURLWithPath: config.out, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cache = out.appending(path: "signal.json")

        var lines: [String] = []
        let signal: MomentSignal
        if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(MomentSignal.self, from: data) {
            signal = saved
            lines.append("Scan: cached signal, \(signal.count) s")
        } else {
            let started = Date()
            let result = try await MomentListener.listen(to: URL(fileURLWithPath: config.video), progress: { _ in }, checkpoint: { _ in })
            signal = result.signal
            try JSONEncoder().encode(signal).write(to: cache)
            lines.append("Scan: isComplete=\(result.isComplete), \(signal.count) s heard in \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        }

        let settings = MomentPicker.Settings()
        let s = scored(signal, settings: settings)
        let n = s.score.count
        let cap = limit(n, settings)
        let tailStart = max(0, n - 360)
        lines.append(String(format: "Seconds: %d. Typical score %.3f, spread %.3f, threshold %.3f (= max(%.1f, typical + %.1f × max(spread, 0.25))). Cap %d.",
                            n, s.typical, s.spread, s.threshold, settings.minimumScore, settings.spreads, cap))

        func report(_ name: String, marks: [Double]) {
            let all = peaks(s, threshold: { _ in s.threshold })
            let (chosen, fate) = select(all, limit: cap, marks: marks, settings: settings)
            // The copy must match the app's picker exactly.
            let app = MomentPicker.pick(signal, avoiding: marks, settings: settings).map { Int($0.seconds) }
            XCTAssertEqual(chosen, app, "diagnostic selection matches MomentPicker.pick (\(name))")
            lines.append("")
            lines.append("== \(name): marks avoided \(marks.count); \(all.count) peaks above threshold; chosen \(chosen.count)")
            lines.append("Chosen: \(chosen.map { "\($0)" }.joined(separator: " "))")
            lines.append("min | s>=thr | best score | peaks | chosen | cap | spacing | marks")
            for minute in 0..<Int((Double(n) / 60).rounded(.up)) {
                let range = (minute * 60)..<min(n, minute * 60 + 60)
                let above = range.filter { s.score[$0] >= s.threshold }.count
                let best = range.map { s.score[$0] }.max() ?? 0
                let inMinute = all.filter { range.contains($0) }
                func count(_ f: Fate) -> Int { inMinute.filter { fate[$0] == f }.count }
                lines.append(String(format: "%3d | %6d | %10.2f | %5d | %6d | %3d | %7d | %5d%@",
                                    minute, above, best, inMinute.count, count(.chosen), count(.cap), count(.spacing), count(.marks),
                                    range.lowerBound >= tailStart || range.contains(tailStart) ? "  <- last 6 min" : ""))
            }
            let tail = all.filter { $0 >= tailStart }
            lines.append(String(format: "Last 6 min (from %d s): %d s above threshold, best %.2f, %d peaks: %d chosen, %d cap, %d spacing, %d marks. Weakest chosen overall: %.2f",
                                tailStart, (tailStart..<n).filter { s.score[$0] >= s.threshold }.count,
                                (tailStart..<n).map { s.score[$0] }.max() ?? 0, tail.count,
                                tail.filter { fate[$0] == .chosen }.count, tail.filter { fate[$0] == .cap }.count,
                                tail.filter { fate[$0] == .spacing }.count, tail.filter { fate[$0] == .marks }.count,
                                chosen.map { s.score[$0] }.min() ?? 0))
        }
        // As the scan that ran (its suggestions were made before any of them became marks), and
        // as a re-scan would run today, clear of the 16 marks.
        report("As scanned (no marks)", marks: [])
        report("Re-scan today (current marks)", marks: config.marks)

        // Alternatives, compared on the scan as it ran (no marks).
        lines.append("")
        lines.append("== Alternatives (no marks): tail = suggestions from \(tailStart) s; on-found = within 20 s of an existing suggestion")
        lines.append("option | total | tail | on-found")
        func line(_ name: String, _ chosen: [Int]) {
            let tail = chosen.filter { $0 >= tailStart }.count
            let onFound = chosen.filter { c in config.found.contains { abs($0 - Double(c)) < 20 } }.count
            lines.append("\(name) | \(chosen.count) | \(tail) | \(onFound)")
        }
        let base = peaks(s, threshold: { _ in s.threshold })
        line("today", select(base, limit: cap, marks: [], settings: settings).chosen)

        // (a) The same cap, but every 10-minute slice first keeps its best peak.
        for slice in [600, 300] {
            var preset: [Int] = []
            for start in stride(from: 0, to: n, by: slice) {
                if let best = base.first(where: { $0 >= start && $0 < start + slice }),
                   !preset.contains(where: { abs($0 - best) < Int(settings.spacing) }) {
                    preset.append(best)
                }
            }
            line("(a) slices of \(slice / 60) min, cap \(cap)", select(base, limit: cap, marks: [], settings: settings, preset: preset).chosen)
        }

        // (b) The threshold measured within each 10-minute section instead of the whole game.
        let section = 600
        var sectionThreshold = [Double](repeating: s.threshold, count: n)
        for start in stride(from: 0, to: n, by: section) {
            let part = Array(s.score[start..<min(n, start + section)])
            let t = max(settings.minimumScore, MomentPicker.median(part) + settings.spreads * max(MomentPicker.spread(part), 0.25))
            for i in start..<min(n, start + section) { sectionThreshold[i] = t }
        }
        let sectioned = peaks(s, threshold: { sectionThreshold[$0] })
        line("(b) threshold per 10 min, cap \(cap)", select(sectioned, limit: cap, marks: [], settings: settings).chosen)
        lines.append(String(format: "    per-section thresholds: %@", stride(from: 0, to: n, by: section).map { String(format: "%.2f", sectionThreshold[$0]) }.joined(separator: " ")))
        // (b) also needs the cap spread out to change anything when the global top 23 are elsewhere:
        var sectionPreset: [Int] = []
        for start in stride(from: 0, to: n, by: section) {
            if let best = sectioned.first(where: { $0 >= start && $0 < start + section }) { sectionPreset.append(best) }
        }
        line("(b)+(a) per-section threshold, best per 10 min first", select(sectioned, limit: cap, marks: [], settings: settings, preset: sectionPreset).chosen)

        // (c) A lower `spreads` (the threshold), the same strongest-first cap.
        for spreads in [2.5, 2.0, 1.5] {
            var lower = settings
            lower.spreads = spreads
            let t = max(lower.minimumScore, s.typical + spreads * max(s.spread, 0.25))
            line(String(format: "(c) spreads %.1f (threshold %.2f), cap %d", spreads, t, cap),
                 select(peaks(s, threshold: { _ in t }), limit: cap, marks: [], settings: lower).chosen)
        }

        let text = lines.joined(separator: "\n")
        try text.write(to: out.appending(path: "diagnostics.txt"), atomically: true, encoding: .utf8)
        print(text)
    }
}
