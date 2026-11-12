import SwiftData
import SwiftUI

// Player tags (decision 0030): the chip, the tag menu, "Add Player", and the editor in Settings.

extension PlayerColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .teal: .teal
        case .pink: .pink
        case .yellow: .yellow
        }
    }
}

/// A player's color dot and name in a tinted capsule; with no player, a "Tag Player" prompt.
/// Narrower styles for tight spaces: `.short` is "#7" (or the name when there's no number),
/// `.icon` the dot or icon alone. `isPlaceholder` lays it out with no height, to reserve its width
/// on a line of text without making the line taller (the Clip screen, decision 0025).
struct PlayerChip: View {
    enum Style {
        case name, short, icon
    }

    let player: Player?
    var style: Style = .name
    var isPlaceholder = false

    var body: some View {
        label
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(player.map { $0.color.color.opacity(0.18) } ?? Color.secondary.opacity(0.14), in: Capsule())
            .accessibilityLabel(player.map { "Player: \($0.fullLabel)" } ?? "Tag player")
            .frame(height: isPlaceholder ? 0 : nil)
    }

    private var label: Text {
        guard let player else {
            let icon = Text(Image(systemName: "person.crop.circle.badge.plus"))
            return style == .icon ? icon : icon + Text(" Tag Player")
        }
        let dot = Text(Image(systemName: "circle.fill")).foregroundStyle(player.color.color).font(.caption2)
        switch style {
        case .name: return dot + Text(" " + player.name).foregroundStyle(Color.primary)
        case .short: return dot + Text(" " + player.shortLabel).foregroundStyle(Color.primary)
        case .icon: return dot
        }
    }
}

/// The choices behind a "Tag Player" control: each player (checked when current), Untag, and Add Player.
struct PlayerTagMenuItems: View {
    let players: [Player]
    /// The current tag when every clip being tagged shares it; nil otherwise.
    let current: Player?
    var showsUntag = true
    let choose: (Player?) -> Void
    let add: () -> Void

    var body: some View {
        ForEach(players) { player in
            Button {
                choose(player)
            } label: {
                if player.id == current?.id {
                    Label(player.fullLabel, systemImage: "checkmark")
                } else {
                    Text(player.fullLabel)
                }
            }
        }
        Button("Add Player…", systemImage: "plus", action: add)
        if showsUntag {
            Button("Untag", systemImage: "person.slash", role: .destructive) { choose(nil) }
        }
    }
}

/// "Add Player" as an alert with Name and Number fields, so tagging never leaves the screen.
/// The new player gets the next unused color; Settings changes it.
struct AddPlayerAlert: ViewModifier {
    @Binding var isPresented: Bool
    let add: (_ name: String, _ number: String) -> Void
    @State private var name = ""
    @State private var number = ""

    func body(content: Content) -> some View {
        content
            .alert("Add Player", isPresented: $isPresented) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Jersey number (optional)", text: $number)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) { reset() }
                Button("Add") {
                    add(name, number)
                    reset()
                }
            } message: {
                Text("Names and numbers stay on this phone.")
            }
    }

    private func reset() {
        name = ""
        number = ""
    }
}

extension View {
    func addPlayerAlert(isPresented: Binding<Bool>, add: @escaping (_ name: String, _ number: String) -> Void) -> some View {
        modifier(AddPlayerAlert(isPresented: isPresented, add: add))
    }
}

/// Settings → a player: name, number, color, and Delete (their clips become untagged).
struct PlayerEditor: View {
    let player: Player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var number: String
    @State private var color: PlayerColor
    @State private var confirmDelete = false
    @State private var isDeleted = false

    init(player: Player) {
        self.player = player
        _name = State(initialValue: player.name)
        _number = State(initialValue: player.number ?? "")
        _color = State(initialValue: player.color)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Jersey number (optional)", text: $number)
                    .keyboardType(.numberPad)
            }
            Section("Color") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                    ForEach(PlayerColor.allCases) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if option == color {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(option == color ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Button("Delete Player", role: .destructive) { confirmDelete = true }
            } footer: {
                Text(clipCountText)
            }
        }
        .navigationTitle(name.isEmpty ? "Player" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            guard !isDeleted else { return }
            Player.update(player, name: name, number: number, color: color, in: modelContext)
        }
        .confirmationDialog("Delete \(player.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Player", role: .destructive) {
                isDeleted = true
                Player.delete(player, in: modelContext)
                dismiss()
            }
        } message: {
            Text("Their clips stay and become untagged. No clips or videos are deleted.")
        }
    }

    private var clipCountText: String {
        switch player.clips.count {
        case 0: "No clips are tagged with this player."
        case 1: "1 clip is tagged with this player. Deleting the player keeps the clip."
        default: "\(player.clips.count) clips are tagged with this player. Deleting the player keeps the clips."
        }
    }
}
