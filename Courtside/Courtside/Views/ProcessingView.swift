import SwiftData
import SwiftUI

struct ProcessingView: View {
    let game: Game
    let modelContext: ModelContext
    /// Picking up clips that iOS cut off earlier (decision 0017).
    var resuming = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var extractor = ClipExtractor()
    @State private var askAboutVideo = false
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            switch extractor.phase {
            case .idle, .running:
                running
            case .finished:
                finished
            case .cancelled:
                summary(
                    icon: "pause.circle",
                    title: "Stopped",
                    detail: "\(extractor.completed) clips made. The rest will be waiting on the game page."
                )
            case .interrupted:
                summary(
                    icon: "pause.circle",
                    title: "Paused",
                    detail: "Courtside was in the background too long. Your clips will finish when you come back."
                )
            }
            Spacer()
            Button {
                if isStoppable {
                    extractor.cancel()
                } else {
                    dismiss()
                }
            } label: {
                Text(isStoppable ? "Stop" : "Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .interactiveDismissDisabled()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            isFinishing = resuming
            extractor.start(game: game, context: modelContext)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            extractor.cancel()
        }
        .onChange(of: scenePhase) { _, _ in resumeIfInterrupted() }
        .onChange(of: extractor.phase) { _, phase in
            resumeIfInterrupted()
            if phase == .finished, extractor.completed > 0, game.isVideoAvailable, !game.keepsVideo {
                askAboutVideo = true
            }
        }
        .alert("Keep the full game video? (\(Format.bytes(game.videoFileSize)))", isPresented: $askAboutVideo) {
            Button("Keep", role: .cancel) {
                game.keepsVideo = true
                try? modelContext.save()
            }
            Button("Delete", role: .destructive) {
                StorageManager.deleteGameVideo(game, in: modelContext)
            }
        } message: {
            Text(keepVideoMessage)
        }
    }

    private var isStoppable: Bool {
        extractor.phase == .running || extractor.phase == .interrupted
    }

    /// Back on screen after iOS cut the run short: make the clips that are still missing.
    private func resumeIfInterrupted() {
        guard extractor.phase == .interrupted, scenePhase == .active else { return }
        isFinishing = true
        extractor.start(game: game, context: modelContext)
    }

    private var running: some View {
        VStack(spacing: 20) {
            if isFinishing {
                Text("Finishing your clips")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text("Making clip \(extractor.currentIndex) of \(extractor.total)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 6) {
                Text("This clip").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: extractor.currentProgress)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("All clips").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: extractor.overallProgress)
            }
            Text("Keep Courtside open until this finishes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var readyTitle: String {
        "\(extractor.completed) \(extractor.completed == 1 ? "clip" : "clips") ready"
    }

    @ViewBuilder
    private var finished: some View {
        if extractor.failed > 0 {
            summary(
                icon: "exclamationmark.triangle",
                title: readyTitle,
                detail: "\(extractor.failed) couldn't be made. You can try again from the game page."
            )
        } else {
            summary(icon: "checkmark.circle.fill", title: readyTitle, detail: nil)
        }
    }

    private func summary(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.title2.weight(.semibold))
            if let detail {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keepVideoMessage: String {
        var message = "Deleting it frees space but means you can't add more marks or adjust clip timing. You can delete it later from the game page."
        if game.source == .imported {
            message += " The original is still in your Photos library."
        }
        return message
    }
}
