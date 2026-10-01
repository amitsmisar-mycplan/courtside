import SwiftData
import SwiftUI

struct SlowMoSheet: View {
    let clip: Clip
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var session: SlowMoSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    SlowMoEditor(session: session, modelContext: modelContext) { dismiss() }
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
        .onDisappear { session?.tearDown() }
    }
}

private struct SlowMoEditor: View {
    let session: SlowMoSession
    let modelContext: ModelContext
    let onRendered: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // No preview area when the frame rate rules slow motion out entirely.
                if session.frameRate == .loading || !session.availableSpeeds.isEmpty {
                    PlayerSurface(player: session.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            if session.isBuildingPreview {
                                ProgressView().tint(.white)
                            } else if !session.hasPreview {
                                Text("Tap Preview to watch it before saving.")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
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
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button {
                    session.preview()
                } label: {
                    Label("Preview", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Task {
                        if await session.render(context: modelContext) { onRendered() }
                    }
                } label: {
                    Label("Save", systemImage: "tortoise.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canRender)
            }
            .controlSize(.large)
            .disabled(session.isRendering)
        }
    }

    private var summary: String {
        let segment = session.segment
        return String(
            format: "%.1f–%.1f s of the clip plays at %@ · whole video plays as %.0f s · about %@",
            segment.start, segment.end, session.speed.label, session.outputDuration,
            Format.bytes(session.estimatedFileSize)
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
                Label("tap", systemImage: "hand.tap").labelStyle(.titleAndIcon).foregroundStyle(.yellow)
                Spacer()
                Text(Format.duration(duration.rounded(.up)))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
