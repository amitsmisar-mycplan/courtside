import PhotosUI
import SwiftData
import SwiftUI

struct ImportRequest: Identifiable {
    enum Source {
        case photos(PhotosPickerItem)
        case file(URL)
    }

    let id = UUID()
    let source: Source
}

/// Copies the picked video with progress and creates the `Game`, then offers a quick, skippable
/// opponent field. The game already exists by then; details never hold up the import.
struct ImportFlowView: View {
    let request: ImportRequest
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case importing
        case details(Game)
        case failed(String)
    }

    @State private var phase: Phase = .importing
    @State private var progress: Double = 0
    @State private var opponent = ""
    @FocusState private var opponentFocused: Bool
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled()
        .onAppear {
            if importTask == nil { startImport() }
        }
        .onDisappear { importTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .importing:
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("Copying game video… \(Int(progress * 100))%")
                    .font(.headline)
                    .monospacedDigit()
                Text("A full game can take a minute. Keep Courtside open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxHeight: .infinity)
        case .details(let game):
            Form {
                Section {
                    TextField("Opponent", text: $opponent)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($opponentFocused)
                        .onSubmit { save(game) }
                } footer: {
                    Text("Optional. Add the score and notes any time from the game page.")
                }
                Section {
                    LabeledContent("Date", value: game.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Length", value: Format.duration(game.durationSeconds))
                    LabeledContent("Size", value: Format.bytes(game.videoFileSize))
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't import", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch phase {
        case .importing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    importTask?.cancel()
                    dismiss()
                }
            }
        case .details(let game):
            ToolbarItem(placement: .cancellationAction) {
                Button("Later") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(game) }
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var title: String {
        switch phase {
        case .importing: "Importing"
        case .details: "Who Did They Play?"
        case .failed: "Import"
        }
    }

    private func startImport() {
        let source = request.source
        let context = modelContext
        importTask = Task {
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in progress = value }
            }
            do {
                let video: ImportedVideo
                switch source {
                case .photos(let item):
                    video = try await VideoImporter.importFromPhotos(item, progress: report)
                case .file(let url):
                    video = try await VideoImporter.importFromFile(at: url, progress: report)
                }
                let recordedAt = video.createdAt ?? .now
                let game = Game(
                    id: video.gameID,
                    label: "",
                    recordedAt: recordedAt,
                    videoFilename: video.filename,
                    durationSeconds: video.durationSeconds,
                    source: .imported,
                    videoFileSize: video.fileSize
                )
                context.insert(game)
                try context.save()
                phase = .details(game)
                opponentFocused = true
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ game: Game) {
        let name = opponent.trimmed
        if !name.isEmpty {
            game.opponent = name
            try? modelContext.save()
        }
        dismiss()
    }
}
