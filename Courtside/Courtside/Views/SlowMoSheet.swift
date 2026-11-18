import SwiftData
import SwiftUI

struct SlowMoSheet: View {
    let clip: Clip
    let modelContext: ModelContext
    /// Called after a successful save, before the sheet closes, so the clip screen can say so.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var session: SlowMoSession?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    SlowMoEditor(session: session, modelContext: modelContext, showPreview: $showPreview) {
                        onSaved()
                        dismiss()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Slow Mo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session?.isRendering == true)
                }
            }
        }
        .interactiveDismissDisabled(session?.isRendering == true)
        .task {
            if session == nil { session = SlowMoSession(clip: clip) }
            await session?.load()
        }
        .fullScreenCover(isPresented: $showPreview) {
            if let session { SlowMoPreviewPlayer(session: session) }
        }
        // Full-screen preview hides the sheet, which can report a disappear; only a real
        // dismissal of the sheet releases the player.
        .onDisappear {
            guard !showPreview else { return }
            session?.tearDown()
        }
    }
}

private struct SlowMoEditor: View {
    let session: SlowMoSession
    let modelContext: ModelContext
    @Binding var showPreview: Bool
    let onRendered: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // No preview area when the frame rate rules slow motion out entirely.
                if session.frameRate == .loading || !session.availableSpeeds.isEmpty {
                    poster
                }

                switch session.frameRate {
                case .loading:
                    ProgressView("Checking the video…")
                        .frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .loaded:
                    controls
                }
            }
            .padding()
        }
        .overlay {
            if session.isRendering {
                VStack(spacing: 12) {
                    Text("Making slow mo…").font(.headline)
                    ProgressView(value: session.renderProgress)
                }
                .padding(24)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Slow mo didn't work", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let message = session.limitationMessage {
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !session.availableSpeeds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speed").font(.headline)
                HStack(spacing: 10) {
                    ForEach(SlowMoSpeed.allCases) { speed in
                        let available = session.availableSpeeds.contains(speed)
                        Button {
                            session.select(speed)
                        } label: {
                            Text(speed.label)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(session.speed == speed ? .accentColor : .secondary)
                        .disabled(!available)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Slow part").font(.headline)
                SegmentEditor(
                    duration: session.clipDuration,
                    mark: session.markInClip,
                    segment: session.segment
                ) { start, end in
                    session.setSegment(start: start, end: end)
                }
                Text("Drag the circles to choose what slows down. The yellow line is your tap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary)
                    .font(.subheadline)
                    .monospacedDigit()
            }

            // Preview takes what it needs and Save the rest; stacked when they don't fit (large text).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    previewButton(stacked: false)
                    saveButton(stacked: false)
                }
                VStack(spacing: 10) {
                    saveButton(stacked: true)
                    previewButton(stacked: true)
                }
            }
            .controlSize(.large)
            .disabled(session.isRendering)

            // Saving here doesn't touch the camera roll; say where it goes and how to get it there.
            Text("Saved with this clip. Use Save to Photos on the clip screen to put it in your camera roll.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Side by side the labels stay on one line (so the row only fits when they do); stacked they
    /// may wrap rather than be cut off.
    private func previewButton(stacked: Bool) -> some View {
        Button {
            showPreview = true
        } label: {
            Label("Preview", systemImage: "play.fill")
                .lineLimit(stacked ? nil : 1)
                .frame(maxWidth: stacked ? .infinity : nil)
        }
        .buttonStyle(.bordered)
    }

    private func saveButton(stacked: Bool) -> some View {
        Button {
            Task {
                if await session.render(context: modelContext) { onRendered() }
            }
        } label: {
            Label("Save Slow Mo", systemImage: "tortoise.fill")
                .lineLimit(stacked ? nil : 1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!session.canRender)
    }

    /// A still at the tap, at the clip's real shape; tapping it opens the full-screen preview.
    private var poster: some View {
        Button {
            showPreview = true
        } label: {
            ZStack {
                Color.black
                if let image = session.poster {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                if session.frameRate == .loading {
                    ProgressView().tint(.white)
                } else {
                    // A small play icon only: the Preview button below says it in words.
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
            .aspectRatio(session.aspectRatio ?? 16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Portrait clips would push the controls off screen at full width.
            .frame(maxWidth: .infinity, maxHeight: 340)
        }
        .buttonStyle(.plain)
        .disabled(session.isRendering || session.availableSpeeds.isEmpty)
        .accessibilityLabel("Preview")
        .accessibilityHint("Plays the slow mo full screen")
    }

    /// Plain words: how long the slow part is, how long the saved video plays, and its size.
    private var summary: String {
        String(
            format: "Slow part: %.1f s. Final video: %.0f s. About %@.",
            session.segment.duration, session.outputDuration, Format.bytes(session.estimatedFileSize)
        )
    }
}

/// Clip timeline with a draggable slow segment: drag either edge, or the middle to move it.
private struct SegmentEditor: View {
    let duration: Double
    let mark: Double
    let segment: SlowMoSegment
    let onChange: (Double, Double) -> Void

    @State private var dragOrigin: SlowMoSegment?

    private let handleSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width - handleSize
                let x = { (seconds: Double) in handleSize / 2 + width * seconds / max(duration, 0.001) }
                let seconds = { (dx: CGFloat) in Double(dx / max(width, 1)) * duration }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 8)
                        .padding(.horizontal, handleSize / 2)

                    // Slow segment; drag the middle to move it.
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(x(segment.end) - x(segment.start), 4), height: 24)
                        .offset(x: x(segment.start))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let origin = dragOrigin ?? segment
                                    dragOrigin = origin
                                    let shift = min(max(seconds(value.translation.width), -origin.start), duration - origin.end)
                                    onChange(origin.start + shift, origin.end + shift)
                                }
                                .onEnded { _ in dragOrigin = nil }
                        )

                    // The tap.
                    Rectangle()
                        .fill(.yellow)
                        .frame(width: 3, height: 32)
                        .offset(x: x(mark) - 1.5)
                        .allowsHitTesting(false)

                    handle(at: x(segment.start)) { dx in
                        let origin = dragOrigin ?? segment
                        dragOrigin = origin
                        onChange(min(origin.start + seconds(dx), origin.end - SlowMotion.minimumSegment), origin.end)
                    }
                    handle(at: x(segment.end)) { dx in
                        let origin = dragOrigin ?? segment
                        dragOrigin = origin
                        onChange(origin.start, max(origin.end + seconds(dx), origin.start + SlowMotion.minimumSegment))
                    }
                }
                .frame(height: 36)
            }
            .frame(height: 36)

            HStack {
                Text("0:00")
                Spacer()
                Text(Format.duration(duration.rounded(.up)))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            // "your tap", centred under the yellow line (kept inside the timeline at its ends).
            GeometryReader { geometry in
                let width = geometry.size.width - handleSize
                let x = handleSize / 2 + width * mark / max(duration, 0.001)
                Text("your tap")
                    .font(.caption2.weight(.semibold))
                    // The marker's yellow, darkened enough to read on white.
                    .foregroundStyle(Color(red: 0.7, green: 0.55, blue: 0))
                    .fixedSize()
                    .position(x: min(max(x, 28), geometry.size.width - 28), y: 8)
            }
            .frame(height: 16)
            .accessibilityHidden(true)
        }
    }

    private func handle(at position: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Circle()
            .fill(.white)
            .shadow(radius: 2)
            .frame(width: handleSize, height: handleSize)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
            .offset(x: position - handleSize / 2)
            .gesture(
                DragGesture()
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}
