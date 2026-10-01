import SwiftData
import SwiftUI

struct GameDetailView: View {
    @Bindable var game: Game
    @Environment(\.modelContext) private var modelContext

    @State private var showMarking = false
    @State private var showProcessing = false
    @State private var isRenaming = false
    @State private var draftLabel = ""
    @State private var confirmDeleteVideo = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                actions
                clips
            }
            .padding()
        }
        .navigationTitle(game.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") {
                    draftLabel = game.label
                    isRenaming = true
                }
            }
        }
        .alert("Rename Game", isPresented: $isRenaming) {
            TextField("Label", text: $draftLabel)
            Button("Save") {
                let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    game.label = trimmed
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
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
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(clips.count == 1 ? "1 Clip" : "\(clips.count) Clips")
                    .font(.headline)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(clips) { clip in
                        NavigationLink(value: clip) {
                            ClipThumbnailView(clip: clip)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
            .overlay(alignment: .bottomLeading) {
                Text(Format.duration(clip.startSeconds))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
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
