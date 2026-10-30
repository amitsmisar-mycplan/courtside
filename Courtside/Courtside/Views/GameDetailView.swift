import SwiftData
import SwiftUI

struct GameDetailView: View {
    @Bindable var game: Game
    @Environment(\.modelContext) private var modelContext

    @State private var showMarking = false
    @State private var showProcessing = false
    @State private var isEditing = false
    @State private var confirmDeleteVideo = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmDeleteSelected = false

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
            clips
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .bottomBar) {
                    Button(deleteSelectedTitle, role: .destructive) { deleteSelected() }
                        .tint(.red)
                        .disabled(selection.isEmpty)
                }
            }
        }
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
        .fullScreenCover(isPresented: $showMarking, onDismiss: {
            if !game.pendingMarks.isEmpty { showProcessing = true }
        }) {
            PlaybackMarkingView(game: game, modelContext: modelContext)
        }
        .confirmationDialog(
            "Delete the full game video?",
            isPresented: $confirmDeleteVideo,
            titleVisibility: .visible
        ) {
            Button("Delete Full Video (\(Format.bytes(game.videoFileSize)))", role: .destructive) {
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
        if !game.isVideoAvailable {
            Text("The full game video was deleted. Your clips are kept, but you can't add marks or adjust clip timing.")
        } else if let expiresAt = game.videoExpiresAt {
            Text("Full game video (\(Format.bytes(game.videoFileSize))) is kept until \(expiresAt.formatted(date: .abbreviated, time: .omitted)).")
        } else if game.keepsVideo {
            HStack {
                Text("Full game video (\(Format.bytes(game.videoFileSize))) is kept.")
                Button("Delete…", role: .destructive) { confirmDeleteVideo = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                showMarking = true
            } label: {
                Label(game.marks.isEmpty ? "Watch and Mark Plays" : "Mark More Plays", systemImage: "hand.tap")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!game.isVideoAvailable)

            let pending = game.pendingMarks.count
            if pending > 0 && game.isVideoAvailable {
                Button {
                    showProcessing = true
                } label: {
                    Label("Make \(pending) \(pending == 1 ? "Clip" : "Clips")", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var clips: some View {
        let clips = game.sortedClips
        if clips.isEmpty {
            ContentUnavailableView {
                Label("No clips yet", systemImage: "film.stack")
            } description: {
                Text("Watch the game and tap the screen whenever something good happens. Each tap becomes a clip.")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(clips) { clip in
                    NavigationLink(value: clip) {
                        ClipRow(clip: clip)
                    }
                    .tag(clip.id)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete([clip]) }
                    }
                }
            } header: {
                HStack {
                    Text(clips.count == 1 ? "1 Clip" : "\(clips.count) Clips")
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

/// A clip in the game's list: thumbnail, where it sits in the game, and its length.
private struct ClipRow: View {
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnailView(clip: clip)
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.duration(clip.startSeconds)) – \(Format.duration(clip.endSeconds))")
                    .font(.headline.monospacedDigit())
                HStack(spacing: 8) {
                    Text("\(Int(clip.window.duration.rounded())) sec")
                    if clip.hasSlowMo {
                        Label("Slow Mo", systemImage: "tortoise.fill")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
