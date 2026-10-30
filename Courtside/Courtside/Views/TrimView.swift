import SwiftData
import SwiftUI

/// Trim a clip: drag its start and end over the surrounding game video, then Save to re-cut it.
struct TrimView: View {
    let clip: Clip
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var session: TrimSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    TrimEditor(session: session)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Trim Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session?.isSaving == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await session?.save(context: modelContext) == true { dismiss() }
                        }
                    }
                    .disabled(session?.canSave != true)
                }
            }
        }
        .interactiveDismissDisabled(session?.isSaving == true || session?.hasChanges == true)
        .task {
            if session == nil { session = TrimSession(clip: clip) }
            await session?.load()
        }
        .onDisappear { session?.tearDown() }
    }
}

private struct TrimEditor: View {
    let session: TrimSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let reason = session.unavailableReason {
                    ContentUnavailableView {
                        Label("Can't trim this clip", systemImage: "scissors")
                    } description: {
                        Text(reason)
                    }
                } else {
                    preview
                    VStack(alignment: .leading, spacing: 8) {
                        TrimBar(session: session)
                        HStack {
                            Text("\(Format.duration(session.window.start)) – \(Format.duration(session.window.end))")
                            Spacer()
                            Text(String(format: "%.1f sec", session.window.duration))
                                .font(.headline)
                        }
                        .monospacedDigit()
                        .font(.subheadline)
                        Text(offsetsText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reset to Default (10 s before, 3 s after)", systemImage: "arrow.counterclockwise") {
                        session.resetToDefault()
                    }
                    .disabled(session.isDefault || session.isSaving)
                    if session.clip.hasSlowMo {
                        Label("Saving a new range removes the slow-mo version; you can make it again after.", systemImage: "tortoise")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .overlay {
            if session.isSaving {
                VStack(spacing: 12) {
                    Text("Trimming clip…").font(.headline)
                    ProgressView(value: session.saveProgress)
                }
                .padding(24)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Couldn't trim the clip", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var preview: some View {
        PlayerSurface(player: session.player)
            .aspectRatio(session.aspectRatio ?? 16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if !session.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { session.togglePlayback() }
            .accessibilityLabel(session.isPlaying ? "Pause preview" : "Play preview")
    }

    private var offsetsText: String {
        let before = session.mark - session.window.start
        let after = session.window.end - session.mark
        let describe = { (value: Double, side: String) -> String in
            value >= 0 ? String(format: "%.1f s %@ the tap", value, side) : String(format: "starts %.1f s after the tap", -value)
        }
        if before < 0 { return describe(before, "before") }
        if after < 0 { return String(format: "ends %.1f s before the tap", -after) }
        return "\(describe(before, "before")) · \(describe(after, "after"))"
    }
}

/// Frames from the surrounding game video, with the kept range between two handles and the tap in yellow.
private struct TrimBar: View {
    let session: TrimSession

    private let handleWidth: CGFloat = 18
    private let height: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let bounds = session.bounds
            let width = max(geometry.size.width - handleWidth * 2, 1)
            let x = { (seconds: Double) in handleWidth + width * (seconds - bounds.start) / max(bounds.duration, 0.001) }
            let seconds = { (position: CGFloat) in bounds.start + Double((position - handleWidth) / width) * bounds.duration }
            let startX = x(session.window.start)
            let endX = x(session.window.end)

            ZStack(alignment: .leading) {
                filmstrip
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: handleWidth)

                // Dim what's left out.
                Color.black.opacity(0.55)
                    .frame(width: max(startX - handleWidth, 0), height: height)
                    .offset(x: handleWidth)
                Color.black.opacity(0.55)
                    .frame(width: max(handleWidth + width - endX, 0), height: height)
                    .offset(x: endX)

                // The kept range.
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(endX - startX, 4), height: height)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                // The tap.
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 3, height: height + 10)
                    .offset(x: x(session.mark) - 1.5)
                    .allowsHitTesting(false)

                handle(edge: .start, at: startX - handleWidth, seconds: seconds)
                handle(edge: .end, at: endX, seconds: seconds)
            }
            .frame(height: height + 10)
            .coordinateSpace(name: "trimBar")
        }
        .frame(height: height + 10)
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if session.filmstrip.isEmpty {
                Color.secondary.opacity(0.25)
            } else {
                ForEach(session.filmstrip.indices, id: \.self) { index in
                    Image(uiImage: session.filmstrip[index])
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }

    private func handle(edge: ClipWindow.Edge, at position: CGFloat, seconds: @escaping (CGFloat) -> Double) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: height)
            .overlay {
                Capsule().fill(.white).frame(width: 3, height: 20)
            }
            // A wider invisible target than the visible handle, for fingers.
            .contentShape(Rectangle().inset(by: -12))
            .offset(x: position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimBar"))
                    .onChanged { value in
                        let edgeX = edge == .start ? value.location.x + handleWidth / 2 : value.location.x - handleWidth / 2
                        session.drag(edge, to: seconds(edgeX))
                    }
                    .onEnded { _ in session.endDrag() }
            )
            .accessibilityLabel(edge == .start ? "Clip start" : "Clip end")
    }
}
