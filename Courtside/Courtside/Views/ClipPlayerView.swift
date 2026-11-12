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
    @State private var exportSession: ClipExportSession?
    @State private var shareSession: ClipShareSession?
    @State private var addingPlayer = false
    @Query(sort: \Player.name) private var players: [Player]

    private enum Version: Hashable {
        case original
        case slowMo
    }

    /// Trim re-cuts from the clip's own part (decision 0022).
    private var canTrim: Bool { clip.resolvedPart?.isVideoAvailable == true }

    /// The file being played, shared, and described: the slow-mo render when selected.
    private var currentURL: URL {
        if version == .slowMo, let url = clip.slowMoURL { return url }
        return clip.fileURL
    }

    var body: some View {
        VideoFirstLayout {
            PlayerSurface(player: looper.player)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if looper.playbackFailed {
                        PlaybackFailedNotice(subject: "clip")
                            .padding(12)
                    }
                }
        } controls: {
            controls
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
        .sheet(item: $exportSession, onDismiss: { looper.load(currentURL) }) { session in
            ExportSheet(session: session)
        }
        .sheet(item: $shareSession, onDismiss: { looper.load(currentURL) }) { session in
            ShareProgressSheet(session: session)
        }
        .addPlayerAlert(isPresented: $addingPlayer) { name, number in
            if let player = Player.add(name: name, number: number, in: modelContext) {
                Player.tag([clip], with: player, in: modelContext)
            }
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

    /// Compact so the video gets most of the screen: Trim and Slow Mo side by side, then Save to
    /// Photos with Share and Delete beside it when they fit, else under it.
    private var controls: some View {
        VStack(spacing: 8) {
            // The player tag sits on the info line, so the video keeps its height (decision 0030):
            // its name, else "#7", else its color dot. The chip is drawn over a placeholder with no
            // height, so the line is exactly as tall as its text. Only text too large for one line
            // puts the tag on its own row.
            ViewThatFits(in: .horizontal) {
                infoLine(tag: .name)
                infoLine(tag: .short)
                infoLine(tag: .icon)
                VStack(spacing: 8) {
                    detailsText
                    playerTag(style: .name)
                }
            }

            if clip.hasSlowMo {
                Picker("Version", selection: $version) {
                    Text("Original").tag(Version.original)
                    Text("Slow Mo").tag(Version.slowMo)
                }
                .pickerStyle(.segmented)
            }

            // Side by side when the labels fit on one line (very large text stacks them).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    trimButton
                    slowMoButton
                }
                VStack(spacing: 8) {
                    trimButton
                    slowMoButton
                }
            }
            if !canTrim {
                Text(clip.game?.hasSeveralParts == true
                     ? "This part's video was deleted, so this clip can't be trimmed."
                     : "The full game video was deleted, so this clip can't be trimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // One row when it fits (Share and Delete as narrow tiles), else Save on its own row
            // above Share and Delete, else (very large text) all three stacked.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    saveButton
                        .frame(maxHeight: .infinity)
                    Group {
                        shareButton(compact: true)
                        deleteButton(compact: true)
                    }
                    // Less padding, so the two-line tiles are no taller than Save beside them.
                    .controlSize(.small)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    saveButton
                    HStack(spacing: 8) {
                        shareButton(compact: false)
                        deleteButton(compact: false)
                    }
                }
                VStack(spacing: 8) {
                    saveButton
                    shareButton(compact: false)
                    deleteButton(compact: false)
                }
            }
        }
        .controlSize(.large)
    }

    private func infoLine(tag style: PlayerChip.Style) -> some View {
        HStack(spacing: 10) {
            detailsText
                .fixedSize()
            PlayerChip(player: clip.player, style: style, isPlaceholder: true)
                .font(.subheadline)
                .hidden()
        }
        .overlay(alignment: .trailing) { playerTag(style: style) }
    }

    private var detailsText: some View {
        Text(details)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// Who is in the clip: a chip that opens the player menu, with Add Player inline.
    private func playerTag(style: PlayerChip.Style) -> some View {
        Menu {
            PlayerTagMenuItems(players: players, current: clip.player, showsUntag: clip.player != nil) { player in
                Player.tag([clip], with: player, in: modelContext)
            } add: {
                addingPlayer = true
            }
        } label: {
            PlayerChip(player: clip.player, style: style)
                .font(.subheadline)
        }
    }

    private var trimButton: some View {
        Button {
            looper.pause()
            showTrim = true
        } label: {
            Label("Trim", systemImage: "timeline.selection")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canTrim)
    }

    private var slowMoButton: some View {
        Button {
            showSlowMo = true
        } label: {
            Label(clip.hasSlowMo ? "Change Slow Mo" : "Slow Mo", systemImage: "tortoise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var saveButton: some View {
        Button {
            looper.pause()
            exportSession = ClipExportSession(clip: clip, source: currentURL, context: modelContext)
        } label: {
            Label(version == .slowMo ? "Save Slow Mo to Photos" : "Save to Photos", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .layoutPriority(1)
    }

    private func shareButton(compact: Bool) -> some View {
        Button {
            share()
        } label: {
            ActionLabel(title: "Share", systemImage: "square.and.arrow.up", compact: compact)
        }
        .buttonStyle(.bordered)
    }

    private func deleteButton(compact: Bool) -> some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            ActionLabel(title: "Delete", systemImage: "trash", compact: compact)
        }
        .buttonStyle(.bordered)
    }

    /// With the game label on, a labelled copy is made first (progress sheet) unless one is already
    /// cached; otherwise the clip itself goes straight to the share sheet, as before.
    private func share() {
        let session = ClipShareSession(clipID: clip.id, source: currentURL, label: .forExport(game: clip.game))
        if session.needsRender {
            looper.pause()
            shareSession = session
        } else {
            session.start()
        }
    }

    private var details: String {
        if version == .slowMo, let slowMo = clip.slowMo {
            let output = SlowMotion.outputDuration(clipDuration: clip.window.duration, segment: slowMo.segment, speed: slowMo.speed)
            return String(format: "Slow Mo %@ · plays %.0f sec · %@", slowMo.speed.label, output, Format.bytes(clip.slowMoFileSize ?? 0))
        }
        let times = "\(Format.duration(clip.startSeconds)) – \(Format.duration(clip.endSeconds)) · \(Int(clip.window.duration.rounded())) sec"
        // The part only matters when there's more than one (decision 0022).
        if clip.game?.hasSeveralParts == true, let part = clip.resolvedPart {
            return "\(part.title) · \(times)"
        }
        return times
    }
}

/// A button label: icon beside the title, or, compact, the icon above a small title so the
/// button fits beside a wide one.
private struct ActionLabel: View {
    let title: String
    let systemImage: String
    let compact: Bool

    var body: some View {
        if compact {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption)
            }
            .lineLimit(1)
            .frame(minWidth: 52, maxHeight: .infinity)
        } else {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
    }
}
