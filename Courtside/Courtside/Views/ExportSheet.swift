import SwiftUI

/// Pick a format, watch it render, done: the clip is in the camera roll.
struct ExportSheet: View {
    let session: ClipExportSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Save to Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if session.isBusy {
                            Button("Cancel") { session.cancel() }
                                .disabled(session.phase == .saving)
                        } else if session.phase == .framing {
                            Button("Back") { session.cancelFraming() }
                        } else {
                            Button("Close") { dismiss() }
                        }
                    }
                }
        }
        .presentationDetents(session.phase == .framing ? [.large] : [.medium])
        .interactiveDismissDisabled(session.isBusy)
        .task { await session.load() }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .choosing:
            VStack(spacing: 12) {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        session.choose(format)
                    } label: {
                        HStack(spacing: 14) {
                            FormatIcon(isTall: format == .vertical || (session.sourceSize.map { $0.height > $0.width } ?? false))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.title).font(.headline)
                                Text(format.detail(sourceSize: session.sourceSize)).font(.subheadline).foregroundStyle(.secondary)
                                if format == .original {
                                    // Without a label Original saves the clip as it is, in about a second.
                                    Text(session.addsLabel ? "Adding label, takes longer" : "Fast, no label")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.down")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        case .framing:
            VerticalFramingEditor(session: session)
        case .exporting:
            VStack(spacing: 14) {
                Text("Making \(session.format == .vertical ? "vertical video" : "video")\(session.addsLabel ? " with label" : "")…").font(.headline)
                ProgressView(value: session.progress)
                Text("\(Int(session.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                if let start = session.renderStartedAt {
                    Text("Elapsed \(Text(start, style: .timer))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
        case .saving:
            ProgressView("Saving to Photos…")
                .frame(maxHeight: .infinity)
        case .saved:
            ContentUnavailableView {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
            } description: {
                Text("It's in your camera roll, ready to post.")
            } actions: {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .denied:
            ContentUnavailableView {
                Label("Courtside can't save to Photos", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Photos access is turned off for Courtside. Turn on \"Add Photos Only\" in Settings, then try again.")
            } actions: {
                if let url = PhotoLibraryService.settingsURL {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't save the video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let format = session.format {
                    Button("Try Again") { session.export(format) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Zoom and aim for a Vertical export of a landscape clip (decision 0024): a still from the clip
/// with the 9:16 window over it. Drag to aim, slide to zoom; the session does the math.
private struct VerticalFramingEditor: View {
    let session: ClipExportSession
    /// The drag's translation already passed on, so each change moves the window by the difference.
    @State private var applied: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            preview
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Zoom").font(.headline)
                    Spacer()
                    Text("\(Int((session.framing.zoom * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                if session.maxZoom >= 0.01 {
                    Slider(value: Binding(get: { session.framing.zoom }, set: { session.setZoom($0) }), in: 0...session.maxZoom)
                        .accessibilityLabel("Zoom")
                }
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                if session.isZoomLimited {
                    Label("Zoom limited by video quality", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                session.export(.vertical)
            } label: {
                Label("Save Vertical", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var hint: String {
        let window = session.framingWindow
        if window.height > 1.001 { return "Drag to aim. Blurred background above and below the video." }
        return "Drag to aim. The sides outside the frame are cropped."
    }

    private var preview: some View {
        let ratio = session.sourceSize.map { $0.width / max($0.height, 1) } ?? 16.0 / 9
        return GeometryReader { geometry in
            let size = geometry.size
            let window = session.framingWindow
            let rect = CGRect(x: window.minX * size.width, y: window.minY * size.height,
                              width: window.width * size.width, height: window.height * size.height)
            ZStack {
                if let image = session.previewFrame {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
                // Outside the window is dimmed: it won't be in the video.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { path in path.addRect(rect) }
                    .stroke(Color.white, lineWidth: 2)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let step = CGSize(width: value.translation.width - applied.width,
                                          height: value.translation.height - applied.height)
                        applied = value.translation
                        session.moveWindow(by: CGSize(width: step.width / max(size.width, 1), height: step.height / max(size.height, 1)))
                    }
                    .onEnded { _ in applied = .zero }
            )
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Vertical frame over the clip. Drag to aim.")
    }
}

/// A small frame showing the shape each format saves.
private struct FormatIcon: View {
    let isTall: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: isTall ? 20 : 34, height: isTall ? 34 : 20)
            .frame(width: 36, height: 36)
    }
}
