import SwiftData
import SwiftUI

struct ClipPlayerView: View {
    @Bindable var clip: Clip

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var looper = LoopingClipPlayer()
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var canNudge: Bool { clip.game?.isVideoAvailable == true && !isExporting }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PlayerSurface(player: looper.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if isExporting {
                            ProgressView("Adjusting…")
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                Text("\(Format.duration(clip.startSeconds)) – \(Format.duration(clip.endSeconds)) · \(Int(clip.window.duration.rounded())) sec")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                nudgeControls

                HStack(spacing: 12) {
                    ShareLink(item: clip.fileURL, preview: SharePreview(clip.game?.label ?? "Clip")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isExporting)
            }
            .padding()
        }
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { looper.load(clip.fileURL) }
        .onDisappear { looper.pause() }
        .confirmationDialog("Delete this clip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Clip", role: .destructive) {
                looper.pause()
                StorageManager.deleteClip(clip, in: modelContext)
                dismiss()
            }
        }
        .alert("Couldn't adjust clip", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var nudgeControls: some View {
        VStack(spacing: 10) {
            nudgeRow(title: "Start", earlier: { nudge(start: -1) }, later: { nudge(start: 1) })
            nudgeRow(title: "End", earlier: { nudge(end: -1) }, later: { nudge(end: 1) })
            if clip.game?.isVideoAvailable != true {
                Text("The full game video was deleted, so this clip's timing can't be adjusted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canNudge)
    }

    private func nudgeRow(title: String, earlier: @escaping () -> Void, later: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .frame(width: 56, alignment: .leading)
            Button(action: earlier) {
                Label("1 sec earlier", systemImage: "backward.frame")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button(action: later) {
                Label("1 sec later", systemImage: "forward.frame")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func nudge(start: Double = 0, end: Double = 0) {
        isExporting = true
        looper.pause()
        Task {
            do {
                try await ClipExtractor.nudge(clip, startBy: start, endBy: end, context: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
            looper.load(clip.fileURL)
            isExporting = false
        }
    }
}
