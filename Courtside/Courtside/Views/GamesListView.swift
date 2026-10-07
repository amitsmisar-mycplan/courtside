import PhotosUI
import SwiftData
import SwiftUI

struct GamesListView: View {
    @Query(sort: \Game.recordedAt, order: .reverse) private var games: [Game]
    @Environment(\.modelContext) private var modelContext

    @State private var showPhotosPicker = false
    @State private var photosSelection: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var importRequest: ImportRequest?
    @State private var gamePendingDelete: Game?
    @State private var showSettings = false
    @State private var showRecording = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            Group {
                if games.isEmpty {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "basketball")
                    } description: {
                        Text("Import a game you've already filmed, tap whenever something good happens, and get your kid's clips.")
                    }
                } else {
                    gameList
                }
            }
            .navigationTitle("Games")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                addGameButton
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .navigationDestination(for: Game.self) { game in
                GameDetailView(game: game)
            }
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
            importRequest = ImportRequest(source: .photos(item))
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url): importRequest = ImportRequest(source: .file(url))
            case .failure(let error): pickerError = error.localizedDescription
            }
        }
        .sheet(item: $importRequest) { request in
            ImportFlowView(request: request, modelContext: modelContext)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showRecording) {
            RecordingView(modelContext: modelContext)
        }
        .confirmationDialog(
            "Delete this game?",
            isPresented: Binding(get: { gamePendingDelete != nil }, set: { if !$0 { gamePendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: gamePendingDelete
        ) { game in
            Button("Delete Game and \(game.clips.count) Clips", role: .destructive) {
                StorageManager.deleteGame(game, in: modelContext)
            }
        } message: { game in
            Text("\(game.label) will be removed from Courtside along with its video, marks and clips. This frees \(Format.bytes(game.storageBytes)).")
        }
        .alert("Couldn't open file", isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerError ?? "")
        }
    }

    private var gameList: some View {
        List {
            Section {
                ForEach(games) { game in
                    NavigationLink(value: game) {
                        GameRow(game: game)
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash") { gamePendingDelete = game }
                            .tint(.red)
                    }
                }
            } header: {
                Text("\(Format.bytes(games.reduce(0) { $0 + $1.storageBytes })) used")
            }
        }
    }

    private var addGameButton: some View {
        Menu {
            Button("Import from Photos", systemImage: "photo.on.rectangle") { showPhotosPicker = true }
            Button("Import from Files", systemImage: "folder") { showFileImporter = true }
            Button("Record Game", systemImage: "video") { showRecording = true }
        } label: {
            Label("Add Game", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
    }
}

private struct GameRow: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.label)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                SourceBadge(source: game.source)
            }
            Text(game.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("\(game.clips.count)", systemImage: "film.stack")
                Label(Format.duration(game.durationSeconds), systemImage: "clock")
                Label(Format.bytes(game.storageBytes), systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SourceBadge: View {
    let source: GameSource

    var body: some View {
        Text(source.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
