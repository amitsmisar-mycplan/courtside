import CoreGraphics
import Foundation

/// The label burned into exported clips (decision 0019): "Team vs Opponent" over
/// "Tournament · Nov 1, 2026". Pure rules: text, fitting, timing. Drawing is in `ExportOverlay`.
struct GameLabel: Equatable, Sendable {
    /// One or two lines, never empty strings.
    let lines: [String]

    /// Nil when there's nothing to say: team, opponent and tournament all empty. The date alone
    /// isn't a label. Score and player names are never included.
    static func make(team: String?, opponent: String?, tournament: String?, date: Date?) -> GameLabel? {
        let team = team?.nonEmpty, opponent = opponent?.nonEmpty, tournament = tournament?.nonEmpty
        guard team != nil || opponent != nil || tournament != nil else { return nil }
        return GameLabel(lines: [matchup(team: team, opponent: opponent), details(tournament: tournament, date: date)].compactMap { $0 })
    }

    /// Line 1: "Team vs Opponent", "vs Opponent", "Team", or nil.
    private static func matchup(team: String?, opponent: String?) -> String? {
        switch (team, opponent) {
        case let (team?, opponent?): "\(team) vs \(opponent)"
        case let (nil, opponent?): "vs \(opponent)"
        case let (team?, nil): team
        case (nil, nil): nil
        }
    }

    /// Line 2: "Tournament · Nov 1, 2026", either part alone, or nil.
    private static func details(tournament: String?, date: Date?) -> String? {
        let parts = [tournament, date.map(formatted)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The label to burn into this game's exports, or nil when the setting is Off or there's no text.
    static func forExport(game: Game?, mode: ExportLabelMode = LabelSettings.exportLabel) -> GameLabel? {
        guard mode == .openAndClose, let game else { return nil }
        return make(team: game.team, opponent: game.opponent, tournament: game.tournament, date: game.recordedAt)
    }

    /// "Nov 1, 2026", the same in every locale, so labels read the same on every phone.
    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: Fitting

    /// Shortens names with "…" until each line is at most `maxWidth` wide. In "Team vs Opponent" the
    /// longer name gives way first; on line 2 only the tournament shrinks, never the date.
    /// `measure(text, line)` returns a line's drawn width (Core Text when drawing; a stand-in in tests).
    static func fitted(
        team: String?, opponent: String?, tournament: String?, date: Date?,
        maxWidth: CGFloat, measure: (String, Int) -> CGFloat
    ) -> GameLabel? {
        var team = team?.nonEmpty, opponent = opponent?.nonEmpty, tournament = tournament?.nonEmpty
        while let text = matchup(team: team, opponent: opponent), measure(text, 0) > maxWidth {
            let teamLength = team?.count ?? 0, opponentLength = opponent?.count ?? 0
            if let current = team, teamLength >= opponentLength, teamLength > 1 {
                team = shortened(current)
            } else if let current = opponent, opponentLength > 1 {
                opponent = shortened(current)
            } else {
                break
            }
        }
        while let text = details(tournament: tournament, date: date), measure(text, 1) > maxWidth,
              let current = tournament, current.count > 1 {
            tournament = shortened(current)
        }
        return make(team: team, opponent: opponent, tournament: tournament, date: date)
    }

    /// One character fewer, ending in "…".
    private static func shortened(_ name: String) -> String {
        let base = name.hasSuffix("…") ? String(name.dropLast()) : name
        return String(base.dropLast()).trimmed + "…"
    }

    // MARK: Suggestions

    /// Tournament names used on other games that match what's typed, most recent game first,
    /// each name once (ignoring case). The exact text already typed isn't suggested.
    static func tournamentSuggestions(matching typed: String, in games: [Game], excluding current: Game? = nil, limit: Int = 5) -> [String] {
        let query = typed.trimmed
        var seen = Set<String>()
        var names: [String] = []
        for game in games.sorted(by: { $0.recordedAt > $1.recordedAt }) where game !== current {
            guard let name = game.tournament?.nonEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if key == query.lowercased() { continue }
            if query.isEmpty || name.localizedCaseInsensitiveContains(query) {
                names.append(name)
            }
        }
        return Array(names.prefix(limit))
    }
}

// MARK: Timing

/// A span of the exported video in which an overlay shows, in seconds.
struct OverlayWindow: Equatable, Sendable {
    let start: Double
    let end: Double
}

enum LabelTiming {
    static let showFor: Double = 2.5
    static let fade: Double = 0.3
    /// Shorter clips get the label at the open only.
    static let minimumForBoth: Double = 7

    /// 2.5 s at the open and 2.5 s at the close; under 7 s, only at the open for a third of the
    /// clip. The two windows are at least 2 s apart, so they never meet.
    static func windows(duration: Double) -> [OverlayWindow] {
        guard duration > 0 else { return [] }
        guard duration >= minimumForBoth else { return [OverlayWindow(start: 0, end: duration / 3)] }
        return [OverlayWindow(start: 0, end: showFor), OverlayWindow(start: duration - showFor, end: duration)]
    }

    /// 0...1: fades in over `fade` seconds at each window's start and out at its end.
    static func opacity(at time: Double, windows: [OverlayWindow], fade: Double = fade) -> Double {
        for window in windows where time >= window.start && time <= window.end {
            let edge = min(time - window.start, window.end - time)
            return fade > 0 ? min(1, max(0, edge / fade)) : 1
        }
        return 0
    }
}

// MARK: Settings

enum ExportLabelMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case openAndClose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .openAndClose: "Open and close"
        }
    }
}

/// How labelled exports are encoded (decision 0021). A label forces a full re-encode; capping it at
/// 1080p makes 4K clips much faster to save and share. Clips themselves are never affected.
enum LabelledExportQuality: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// At most 1920 on the long side, HEVC 1080p preset.
    case hd1080
    /// The clip's own resolution, HEVC Highest Quality: the behavior before decision 0021.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd1080: "1080p (faster)"
        case .full: "Full quality"
        }
    }
}

enum LabelSettings {
    static let myTeamKey = "myTeamName"
    static let exportLabelKey = "exportLabelMode"
    static let labelledQualityKey = "labelledExportQuality"

    /// Prefills new games' team. Nil when not set.
    static var myTeam: String? {
        UserDefaults.standard.string(forKey: myTeamKey)?.nonEmpty
    }

    static var exportLabel: ExportLabelMode {
        UserDefaults.standard.string(forKey: exportLabelKey).flatMap(ExportLabelMode.init(rawValue:)) ?? .openAndClose
    }

    static var labelledQuality: LabelledExportQuality {
        UserDefaults.standard.string(forKey: labelledQualityKey).flatMap(LabelledExportQuality.init(rawValue:)) ?? .hd1080
    }
}
