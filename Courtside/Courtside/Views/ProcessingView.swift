import SwiftData
import SwiftUI

struct ProcessingView: View {
    let game: Game
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var extractor = ClipExtractor()
    @State private var askAboutVideo = false

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
            }
            Spacer()
            Button {
                if extractor.phase == .running {
                    extractor.cancel()
                } else {
                    dismiss()
                }
            } label: {
                Text(extractor.phase == .running ? "Stop" : "Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .interactiveDismissDisabled()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            extractor.start(game: game, context: modelContext)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            extractor.cancel()
        }
        .onChange(of: extractor.phase) { _, phase in
            if phase == .finished, extractor.completed > 0, game.isVideoAvailable {
                askAboutVideo = true
            }
        }
        .alert("Keep the full game video? (\(Format.bytes(game.videoFileSize)))", isPresented: $askAboutVideo) {
            Button("Keep", role: .cancel) {}
            Button("Delete", role: .destructive) {
                StorageManager.deleteGameVideo(game, in: modelContext)
            }
        } message: {
            Text(keepVideoMessage)
        }
    }

    private var running: some View {
        VStack(spacing: 20) {
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

    @ViewBuilder
    private var finished: some View {
        if extractor.failed > 0 {
            summary(
                icon: "exclamationmark.triangle",
                title: "\(extractor.completed) clips ready",
                detail: "\(extractor.failed) couldn't be made. You can try again from the game page."
            )
        } else {
            summary(icon: "checkmark.circle.fill", title: "\(extractor.completed) clips ready", detail: nil)
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
        var message = "Deleting it frees space but means you can't add more marks or adjust clip timing. Kept videos are deleted automatically after 7 days."
        if game.source == .imported {
            message += " The original is still in your Photos library."
        }
        return message
    }
}
