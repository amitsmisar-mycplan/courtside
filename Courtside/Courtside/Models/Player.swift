import Foundation
import SwiftData

/// Someone a clip can be tagged with (decision 0030): a name, an optional jersey number and a
/// color. Players are global, not per game, and stay on this phone: nothing about them is uploaded
/// or added to exported video. Not a roster: no team, season or stats.
@Model final class Player {
    var id: UUID
    var name: String
    /// As printed on the jersey ("7", "00"). Nil when not given.
    var number: String?
    /// A `PlayerColor` raw value.
    var colorName: String
    var createdAt: Date
    /// Deleting a player untags their clips; it never deletes a clip.
    @Relationship(deleteRule: .nullify, inverse: \Clip.player) var clips: [Clip] = []

    init(id: UUID = UUID(), name: String, number: String? = nil, color: PlayerColor = .blue, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.number = number
        self.colorName = color.rawValue
        self.createdAt = createdAt
    }
}

/// The tag colors. Stored by name so the palette can change without a migration.
enum PlayerColor: String, CaseIterable, Identifiable {
    case blue, red, green, orange, purple, teal, pink, yellow

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

extension Player {
    var color: PlayerColor {
        get { PlayerColor(rawValue: colorName) ?? .blue }
        set { colorName = newValue.rawValue }
    }

    /// "#7" when there's a number, for tight spaces; otherwise the name.
    var shortLabel: String { number.map { "#\($0)" } ?? name }

    /// "Sam #7", or just the name.
    var fullLabel: String { number.map { "\(name) #\($0)" } ?? name }

    /// Trims the name and keeps only the digits of the number (at most 3). Nil when the name is empty.
    static func cleaned(name: String, number: String) -> (name: String, number: String?)? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let digits = String(number.filter(\.isASCII).filter(\.isNumber).prefix(3))
        return (name, digits.isEmpty ? nil : digits)
    }

    /// All players, by name.
    @MainActor static func all(in context: ModelContext) -> [Player] {
        let players = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        return players.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds a player with the next unused color. Nil when the name is empty.
    @discardableResult
    @MainActor static func add(name: String, number: String = "", in context: ModelContext) -> Player? {
        guard let cleaned = cleaned(name: name, number: number) else { return nil }
        let used = Set(all(in: context).map(\.colorName))
        let count = (try? context.fetchCount(FetchDescriptor<Player>())) ?? 0
        let color = PlayerColor.allCases.first { !used.contains($0.rawValue) }
            ?? PlayerColor.allCases[count % PlayerColor.allCases.count]
        let player = Player(name: cleaned.name, number: cleaned.number, color: color)
        context.insert(player)
        try? context.save()
        return player
    }

    /// Saves an edit. An empty name keeps the old one.
    @MainActor static func update(_ player: Player, name: String, number: String, color: PlayerColor, in context: ModelContext) {
        if let cleaned = cleaned(name: name, number: number) {
            player.name = cleaned.name
            player.number = cleaned.number
        }
        player.color = color
        try? context.save()
    }

    /// Tags the clips with the player, or untags them with nil. A clip has at most one tag.
    @MainActor static func tag(_ clips: [Clip], with player: Player?, in context: ModelContext) {
        for clip in clips { clip.player = player }
        try? context.save()
    }

    /// Deletes the player: their clips become untagged, and nothing else changes: no clip, mark or
    /// file is removed. Clears "My player" when it was this one.
    @MainActor static func delete(_ player: Player, in context: ModelContext, settings: UserDefaults = .standard) {
        for clip in player.clips { clip.player = nil }
        if PlayerSettings.myPlayerID(in: settings) == player.id {
            PlayerSettings.setMyPlayerID(nil, in: settings)
        }
        context.delete(player)
        try? context.save()
    }
}

/// "My player" and the clip-list filter, remembered across launches.
enum PlayerSettings {
    static let myPlayerKey = "myPlayerID"
    static let clipFilterKey = "clipListFilter"

    static func myPlayerID(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: myPlayerKey).flatMap(UUID.init(uuidString:))
    }

    static func setMyPlayerID(_ id: UUID?, in defaults: UserDefaults = .standard) {
        defaults.set(id?.uuidString ?? "", forKey: myPlayerKey)
    }

    static func clipFilter(in defaults: UserDefaults = .standard) -> ClipFilter {
        defaults.string(forKey: clipFilterKey).flatMap(ClipFilter.init(rawValue:)) ?? .all
    }

    static func setClipFilter(_ filter: ClipFilter, in defaults: UserDefaults = .standard) {
        defaults.set(filter.rawValue, forKey: clipFilterKey)
    }
}

/// Which clips a game's list shows. Stored as a string so `@AppStorage` remembers it.
enum ClipFilter: Hashable, RawRepresentable {
    case all
    case myPlayer
    case untagged
    case player(UUID)

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "myPlayer": self = .myPlayer
        case "untagged": self = .untagged
        default:
            guard rawValue.hasPrefix("player:"), let id = UUID(uuidString: String(rawValue.dropFirst(7))) else { return nil }
            self = .player(id)
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .myPlayer: "myPlayer"
        case .untagged: "untagged"
        case .player(let id): "player:\(id.uuidString)"
        }
    }

    /// The filter as it applies now: one naming a player who no longer exists, or "My player" with
    /// none chosen, shows everything rather than an empty list nobody can explain. A player who has
    /// since become My Player reads as My Player, since the list has no separate chip for them.
    func resolved(myPlayerID: UUID?, playerIDs: Set<UUID>) -> ClipFilter {
        switch self {
        case .all, .untagged: self
        case .myPlayer: myPlayerID.map(playerIDs.contains) == true ? self : .all
        case .player(let id) where id == myPlayerID: playerIDs.contains(id) ? .myPlayer : .all
        case .player(let id): playerIDs.contains(id) ? self : .all
        }
    }

    /// The clips this filter shows, in the order given.
    func apply(to clips: [Clip], myPlayerID: UUID?) -> [Clip] {
        switch self {
        case .all: clips
        case .untagged: clips.filter { $0.player == nil }
        case .myPlayer: myPlayerID.map { id in clips.filter { $0.player?.id == id } } ?? []
        case .player(let id): clips.filter { $0.player?.id == id }
        }
    }
}
