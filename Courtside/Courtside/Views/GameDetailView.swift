import PhotosUI
import SwiftData
import SwiftUI

struct GameDetailView: View {
    @Bindable var game: Game
    @Environment(\.modelContext) private var modelContext

    /// The part being marked (decision 0022); Part 1 for a game with one video.
    @State private var markingPart: GamePart?
    /// The part whose "Find Moments" screen is open (decision 0029).
    @State private var momentsPart: GamePart?
    @State private var showPhotosPicker = false
    @State private var photosSelection: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var importRequest: ImportRequest?
    @State private var pickerError: String?
    @State private var showProcessing = false
    @State private var isEditing = false
    @State private var confirmDeleteVideo = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmDeleteSelected = false
    @State private var addingPlayer = false
    /// Remembered across games and launches (decision 0030).
    @AppStorage(PlayerSettings.clipFilterKey) private var storedFilter = ClipFilter.all
    @AppStorage(PlayerSettings.myPlayerKey) private var myPlayerRaw = ""
    @Query(sort: \Player.name) private var players: [Player]

    var body: some View {
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    summary
                    actions
                }
                // Lists restyle labels (icons dropped or spread out); keep the plain look.
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 2)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            if game.hasSeveralParts {
                parts
            }
            clips
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        PlayerTagMenuItems(players: players, current: sharedTag) { player in
                            tagSelected(with: player)
                        } add: {
                            addingPlayer = true
                        }
                    } label: {
                        // Text, not an icon: the bottom bar would show a label as its icon alone.
                        Text("Tag Player")
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Button(deleteSelectedTitle, role: .destructive) { deleteSelected() }
                        .tint(.red)
                        .disabled(selection.isEmpty)
                }
            }
        }
        .addPlayerAlert(isPresented: $addingPlayer) { name, number in
            if let player = Player.add(name: name, number: number, in: modelContext) {
                tagSelected(with: player)
            }
        }
        .onChange(of: storedFilter) { selection.removeAll() }
        .confirmationDialog(
            "Delete \(selection.count) clips?",
            isPresented: $confirmDeleteSelected,
            titleVisibility: .visible
        ) {
            Button("Delete \(selection.count) Clips", role: .destructive) { delete(selectedClips) }
        } message: {
            Text("Their videos and any slow-mo versions are removed from this phone. The full game video is not affected.")
        }
        .navigationTitle(game.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            GameInfoEditor(game: game, modelContext: modelContext)
        }
        .navigationDestination(for: Clip.self) { clip in
            ClipPlayerView(clip: clip)
        }
        .fullScreenCover(item: $markingPart, onDismiss: {
            if !game.extractableMarks.isEmpty { showProcessing = true }
        }) { part in
            PlaybackMarkingView(game: game, part: part, modelContext: modelContext)
        }
        .fullScreenCover(item: $momentsPart, onDismiss: {
            // Accepted moments are ordinary marks: their clips are made the usual way.
            if !game.extractableMarks.isEmpty { showProcessing = true }
        }) { part in
            MomentsView(part: part, modelContext: modelContext)
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photosSelection,
            matching: .videos,
            preferredItemEncoding: .current
        )
        .onChange(of: photosSelection) { _, item in
            guard let item else { return }
            photosSelection = nil
            importRequest = ImportRequest(source: .photos(item), addingTo: game)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url): importRequest = ImportRequest(source: .file(url), addingTo: game)
            case .failure(let error): pickerError = error.localizedDescription
            }
        }
        .sheet(item: $importRequest) { request in
            ImportFlowView(request: request, modelContext: modelContext)
        }
        .alert("Couldn't open file", isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerError ?? "")
        }
        .confirmationDialog(
            "Delete the full game video?",
            isPresented: $confirmDeleteVideo,
            titleVisibility: .visible
        ) {
            Button(game.hasSeveralParts
                   ? "Delete All Videos (\(Format.bytes(game.availableVideoBytes)))"
                   : "Delete Full Video (\(Format.bytes(game.availableVideoBytes)))", role: .destructive) {
                StorageManager.deleteGameVideo(game, in: modelContext)
            }
        } message: {
            Text("Your clips are kept, but you won't be able to add marks or adjust clip timing.")
        }
        .fullScreenCover(isPresented: $showProcessing) {
            ProcessingView(game: game, modelContext: modelContext)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(game.recordedAt.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                Spacer()
                SourceBadge(source: game.source)
            }
            details
            HStack(spacing: 12) {
                Label(Format.duration(game.durationSeconds), systemImage: "clock")
                Label(game.marks.count == 1 ? "1 mark" : "\(game.marks.count) marks", systemImage: "flag")
                Label(Format.bytes(game.storageBytes), systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            videoStatus
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Score and notes when set; otherwise a nudge to add them, since they're never asked for up front.
    @ViewBuilder
    private var details: some View {
        if game.scoreText != nil || game.notes != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let score = game.scoreText {
                    Text(score)
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                if let notes = game.notes {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .onTapGesture { isEditing = true }
        } else if game.opponent == nil {
            Button("Add opponent and score", systemImage: "square.and.pencil") { isEditing = true }
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var videoStatus: some View {
        if game.hasSeveralParts {
            // Each part's own status is in the Parts list; only the game-wide Keep shows here.
            if game.keepsVideo && game.isVideoAvailable {
                HStack {
                    Text("This game's videos (\(Format.bytes(game.availableVideoBytes))) are kept.")
                    Button("Delete…", role: .destructive) { confirmDeleteVideo = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        } else if !game.isVideoAvailable {
            Text("The full game video was deleted. Your clips are kept, but you can't add marks or adjust clip timing.")
        } else if let expiresAt = game.videoExpiresAt {
            Text("Full game video (\(Format.bytes(game.availableVideoBytes))) is kept until \(expiresAt.formatted(date: .abbreviated, time: .omitted)).")
        } else if game.keepsVideo {
            HStack {
                Text("Full game video (\(Format.bytes(game.availableVideoBytes))) is kept.")
                Button("Delete…", role: .destructive) { confirmDeleteVideo = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            // With several parts, the Parts list below is where marking starts (decision 0022).
            if !game.hasSeveralParts {
                Button {
                    markingPart = game.orderedParts.first
                } label: {
                    Label(game.marks.isEmpty ? "Watch and Mark Plays" : "Mark More Plays", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!game.isVideoAvailable)
            }

            findMoments

            let pending = game.extractableMarks.count
            if pending > 0 {
                Button {
                    showProcessing = true
                } label: {
                    Label("Make \(pending) \(pending == 1 ? "Clip" : "Clips")", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Menu {
                Button("Import from Photos", systemImage: "photo.on.rectangle") { showPhotosPicker = true }
                Button("Import from Files", systemImage: "folder") { showFileImporter = true }
            } label: {
                Label("Add Video", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// Listens to a part's sound for crowd reactions (decision 0029). With several parts, pick one.
    @ViewBuilder
    private var findMoments: some View {
        let parts = game.orderedParts.filter(\.isVideoAvailable)
        if parts.count > 1 || game.hasSeveralParts {
            Menu {
                ForEach(parts) { part in
                    Button(momentsMenuTitle(for: part)) { momentsPart = part }
                }
            } label: {
                Label("Find Moments", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(parts.isEmpty)
        } else {
            let part = parts.first
            let pending = part?.pendingSuggestionCount ?? 0
            Button {
                momentsPart = part
            } label: {
                Label(pending > 0 ? "Review \(pending) \(pending == 1 ? "Moment" : "Moments")" : "Find Moments",
                      systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(part == nil)
        }
    }

    private func momentsMenuTitle(for part: GamePart) -> String {
        let pending = part.pendingSuggestionCount
        return pending > 0 ? "\(part.title) · \(pending) to review" : part.title
    }

    /// One row per video, in the order added; tap one to mark it.
    private var parts: some View {
        Section {
            ForEach(game.orderedParts) { part in
                Button {
                    markingPart = part
                } label: {
                    PartRow(part: part)
                }
                .disabled(!part.isVideoAvailable)
            }
        } header: {
            Text("\(game.parts.count) Parts")
        } footer: {
            Text("Tap a part to watch it and mark plays.")
        }
    }

    @ViewBuilder
    private var clips: some View {
        let allClips = game.sortedClips
        let filter = activeFilter
        let clips = filter.apply(to: allClips, myPlayerID: myPlayerID)
        if allClips.isEmpty {
            ContentUnavailableView {
                Label("No clips yet", systemImage: "film.stack")
            } description: {
                Text("Watch the game and tap the screen whenever something good happens. Each tap becomes a clip.")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                if clips.isEmpty {
                    VStack(spacing: 8) {
                        Text(emptyFilterText(filter))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Show All Clips") { storedFilter = .all }
                            .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                ForEach(clips) { clip in
                    NavigationLink(value: clip) {
                        ClipRow(clip: clip, showsPart: game.hasSeveralParts)
                    }
                    .tag(clip.id)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete([clip]) }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    if !players.isEmpty {
                        filterChips(selected: filter)
                    }
                    clipsHeaderRow(shown: clips.count, total: allClips.count)
                }
            }
        }
    }

    // MARK: Player filter (decision 0030)

    private var myPlayerID: UUID? { UUID(uuidString: myPlayerRaw) }
    private var myPlayer: Player? { players.first { $0.id == myPlayerID } }

    /// The remembered filter, or All when it names a player who's gone.
    private var activeFilter: ClipFilter {
        storedFilter.resolved(myPlayerID: myPlayerID, playerIDs: Set(players.map(\.id)))
    }

    /// All / My Player / Untagged / each other player. Scrolls sideways when they don't fit.
    private func filterChips(selected: ClipFilter) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All", filter: .all, selected: selected)
                if let myPlayer {
                    filterChip("My Player", color: myPlayer.color, filter: .myPlayer, selected: selected)
                }
                filterChip("Untagged", filter: .untagged, selected: selected)
                ForEach(players.filter { $0.id != myPlayerID }) { player in
                    filterChip(player.name, color: player.color, filter: .player(player.id), selected: selected)
                }
            }
            .padding(.vertical, 2)
        }
        .textCase(nil)
        .scrollClipDisabled()
    }

    private func filterChip(_ title: String, color: PlayerColor? = nil, filter: ClipFilter, selected: ClipFilter) -> some View {
        let isOn = filter == selected
        return Button {
            storedFilter = filter
        } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle()
                        .fill(color.color)
                        .frame(width: 8, height: 8)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel("Show \(title)")
    }

    private func emptyFilterText(_ filter: ClipFilter) -> String {
        switch filter {
        case .untagged: "Every clip in this game is tagged."
        case .myPlayer: "No clips in this game are tagged with \(myPlayer?.name ?? "your player")."
        case .player(let id): "No clips in this game are tagged with \(players.first { $0.id == id }?.name ?? "this player")."
        case .all: ""
        }
    }

    /// The tag every selected clip shares, for the menu's checkmark; nil when they differ.
    private var sharedTag: Player? {
        let tags = Set(selectedClips.map { $0.player?.id })
        guard tags.count == 1 else { return nil }
        return selectedClips.first?.player
    }

    private func tagSelected(with player: Player?) {
        Player.tag(selectedClips, with: player, in: modelContext)
        withAnimation {
            selection.removeAll()
            editMode = .inactive
        }
    }

    private func clipsHeaderRow(shown: Int, total: Int) -> some View {
        HStack {
            Text(shown == total
                 ? (total == 1 ? "1 Clip" : "\(total) Clips")
                 : "\(shown) of \(total) Clips")
            Spacer()
            Button(editMode.isEditing ? "Done" : "Select") {
                withAnimation {
                    editMode = editMode.isEditing ? .inactive : .active
                    selection.removeAll()
                }
            }
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
        }
    }

    private var selectedClips: [Clip] {
        game.clips.filter { selection.contains($0.id) }
    }

    private var deleteSelectedTitle: String {
        switch selection.count {
        case 0: "Delete"
        case 1: "Delete 1 Clip"
        default: "Delete \(selection.count) Clips"
        }
    }

    /// One clip goes straight away; more than one asks first.
    private func deleteSelected() {
        if selection.count > 1 {
            confirmDeleteSelected = true
        } else {
            delete(selectedClips)
        }
    }

    private func delete(_ clips: [Clip]) {
        StorageManager.deleteClips(clips, in: modelContext)
        selection.removeAll()
        if game.clips.isEmpty { editMode = .inactive }
    }
}

/// A part in the game's Parts list: its name, length and what happens to its video.
private struct PartRow: View {
    let part: GamePart

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(part.title) · \(Format.duration(part.durationSeconds))")
                    .font(.headline.monospacedDigit())
                    // Plain colours: inside a button the hierarchical styles take the accent tint.
                    .foregroundStyle(part.isVideoAvailable ? Color.primary : Color.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if part.isVideoAvailable {
                Image(systemName: "hand.tap")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var status: String {
        let marks = part.marks.count == 1 ? "1 mark" : "\(part.marks.count) marks"
        if !part.isVideoAvailable { return "\(marks) · Video deleted" }
        if let expiresAt = part.videoExpiresAt {
            return "\(marks) · Video kept until \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(marks) · \(Format.bytes(part.videoFileSize))"
    }
}

/// A clip in the game's list: thumbnail, where it sits in the game, and its length. The part is
/// named only when the game has more than one.
private struct ClipRow: View {
    let clip: Clip
    var showsPart = false

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnailView(clip: clip)
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(times)
                    .font(.headline.monospacedDigit())
                // The tag fits beside the length, else "#7", else on its own line (large text), where
                // it narrows the same way, down to its color dot.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        facts
                        tag(.name)
                    }
                    HStack(spacing: 8) {
                        facts
                        tag(.short)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        facts
                        ViewThatFits(in: .horizontal) {
                            tag(.name)
                            tag(.short)
                            tag(.icon)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private var facts: some View {
        HStack(spacing: 8) {
            Text("\(Int(clip.window.duration.rounded())) sec")
            if clip.hasSlowMo {
                Label("Slow Mo", systemImage: "tortoise.fill")
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func tag(_ style: PlayerChip.Style) -> some View {
        if let player = clip.player {
            PlayerChip(player: player, style: style)
                .font(.caption)
        }
    }

    private var times: String {
        let range = "\(Format.duration(clip.startSeconds)) – \(Format.duration(clip.endSeconds))"
        guard showsPart, let part = clip.resolvedPart else { return range }
        return "\(part.title) · \(range)"
    }
}

struct ClipThumbnailView: View {
    let clip: Clip
    @State private var image: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: "\(clip.id)-\(clip.startSeconds)-\(clip.endSeconds)") {
                image = await ThumbnailGenerator.thumbnail(
                    clipID: clip.id,
                    clipURL: clip.fileURL,
                    clipDuration: clip.window.duration
                )
            }
    }
}
