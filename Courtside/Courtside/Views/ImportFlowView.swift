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

/// Copies the picked video with progress, creates the `Game`, then lets the parent edit its label.
struct ImportFlowView: View {
    let request: ImportRequest
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case importing
        case naming(Game)
        case failed(String)
    }

    @State private var phase: Phase = .importing
    @State private var progress: Double = 0
    @State private var label = ""
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
        case .naming(let game):
            Form {
                Section("Label") {
                    TextField("Label", text: $label)
                        .submitLabel(.done)
                        .onSubmit { save(game) }
                }
                Section {
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
        case .naming(let game):
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
        case .naming: "Name This Game"
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
                    label: Game.defaultLabel(for: recordedAt),
                    recordedAt: recordedAt,
                    videoFilename: video.filename,
                    durationSeconds: video.durationSeconds,
                    source: .imported,
                    videoFileSize: video.fileSize
                )
                context.insert(game)
                try context.save()
                label = game.label
                phase = .naming(game)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ game: Game) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            game.label = trimmed
            try? modelContext.save()
        }
        dismiss()
    }
}
