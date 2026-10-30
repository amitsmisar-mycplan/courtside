import SwiftData
import SwiftUI

struct ClipPlayerView: View {
    @Bindable var clip: Clip

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var looper = LoopingClipPlayer()
    @State private var confirmDelete = false
    @State private var version: Version = .original
    @State private var showSlowMo = false
    @State private var showTrim = false

    private enum Version: Hashable {
        case original
        case slowMo
    }

    private var canTrim: Bool { clip.game?.isVideoAvailable == true }

    /// The file being played, shared, and described: the slow-mo render when selected.
    private var currentURL: URL {
        if version == .slowMo, let url = clip.slowMoURL { return url }
        return clip.fileURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PlayerSurface(player: looper.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if looper.playbackFailed {
                            PlaybackFailedNotice(subject: "clip")
                                .padding(12)
                        }
                    }

                if clip.hasSlowMo {
                    Picker("Version", selection: $version) {
                        Text("Original").tag(Version.original)
                        Text("Slow Mo").tag(Version.slowMo)
                    }
                    .pickerStyle(.segmented)
                }

                Text(details)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                trimControl

                Button {
                    showSlowMo = true
                } label: {
                    Label(clip.hasSlowMo ? "Change Slow Mo" : "Slow Mo", systemImage: "tortoise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                HStack(spacing: 12) {
                    ShareLink(item: currentURL, preview: SharePreview(clip.game?.displayTitle ?? "Clip")) {
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
            }
            .padding()
        }
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { looper.load(currentURL) }
        .onDisappear { looper.pause() }
        .onChange(of: version) { looper.load(currentURL) }
        .onChange(of: clip.slowMoFilename) { _, filename in
            // Rendered, re-rendered, or removed (deleted, or cleared by a trim).
            version = filename == nil ? .original : .slowMo
            looper.load(currentURL)
        }
        .sheet(isPresented: $showSlowMo) {
            SlowMoSheet(clip: clip, modelContext: modelContext)
        }
        .sheet(isPresented: $showTrim, onDismiss: {
            // A saved trim replaced the file in place; read it fresh.
            looper.load(currentURL)
        }) {
            TrimView(clip: clip, modelContext: modelContext)
        }
        .confirmationDialog(
            clip.hasSlowMo ? "Delete what?" : "Delete this clip?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            if clip.hasSlowMo {
                Button("Delete Slow Mo Version Only", role: .destructive) {
                    StorageManager.deleteSlowMo(of: clip, in: modelContext)
                }
            }
            Button(clip.hasSlowMo ? "Delete Clip and Slow Mo" : "Delete Clip", role: .destructive) {
                looper.pause()
                StorageManager.deleteClip(clip, in: modelContext)
                dismiss()
            }
        }
    }

    /// Opens the trim editor, or says why it can't.
    @ViewBuilder
    private var trimControl: some View {
        Button {
            looper.pause()
            showTrim = true
        } label: {
            Label("Trim", systemImage: "timeline.selection")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canTrim)
        if clip.game?.isVideoAvailable != true {
            Text("The full game video was deleted, so this clip can't be trimmed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var details: String {
        if version == .slowMo, let slowMo = clip.slowMo {
            let output = SlowMotion.outputDuration(clipDuration: clip.window.duration, segment: slowMo.segment, speed: slowMo.speed)
            return String(format: "Slow Mo %@ · plays %.0f sec · %@", slowMo.speed.label, output, Format.bytes(clip.slowMoFileSize ?? 0))
        }
        return "\(Format.duration(clip.startSeconds)) – \(Format.duration(clip.endSeconds)) · \(Int(clip.window.duration.rounded())) sec"
    }
}
