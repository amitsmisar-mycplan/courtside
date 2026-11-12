import SwiftUI

/// Pick a format, watch it render, done: the clip is in the camera roll.
struct ExportSheet: View {
    let session: ClipExportSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            content
                // The framing editor lays out its own margins (video first, decision 0025).
                .padding(session.phase == .framing ? [] : .all)
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
        .onDisappear { session.close() }
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

/// Zoom and aim for a Vertical export of a landscape clip (decisions 0024 and 0028): the clip
/// playing under the 9:16 window, a scrub bar with the aim points, and the zoom. The session does
/// the math; this only draws it and sends what the parent did.
private struct VerticalFramingEditor: View {
    let session: ClipExportSession
    /// The drag's translation already passed on, so each change moves the window by the difference.
    @State private var applied: CGSize = .zero

    var body: some View {
        VideoFirstLayout(minVideoHeight: 160, spacing: 12) {
            preview
        } controls: {
            VStack(spacing: 12) {
                AimTimelineBar(session: session)
                pointControls
                zoomControls
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
    }

    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    playButton
                    timeLabel
                    Spacer(minLength: 0)
                    pointButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        playButton
                        timeLabel
                    }
                    pointButton
                }
            }
            Text(hint).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playButton: some View {
        Button {
            session.togglePlay()
        } label: {
            Image(systemName: session.preview.isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(session.preview.isPlaying ? "Pause" : "Play")
    }

    private var timeLabel: some View {
        Text("\(Format.duration(session.preview.currentTime)) / \(Format.duration(session.preview.duration))")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pointButton: some View {
        if session.canDeletePoint {
            Button(role: .destructive) {
                session.deletePoint()
            } label: {
                Label("Delete Point", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                session.addPoint()
            } label: {
                Label("Add Point", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canAddPoint)
        }
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Zoom").font(.headline)
                Spacer()
                Text("\(Int((session.zoom * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            if session.maxZoom >= 0.01 {
                Slider(value: Binding(get: { session.zoom }, set: { session.setZoom($0) }), in: 0...session.maxZoom)
                    .accessibilityLabel("Zoom")
            }
            if session.framingWindow.height > 1.001 {
                Text("Blurred background above and below the video.").font(.footnote).foregroundStyle(.secondary)
            }
            if session.isZoomLimited {
                Label("Zoom limited by video quality", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String {
        if session.draft != nil { return "Tap Add Point to keep this aim." }
        if session.aimKeys.count == 1 {
            return session.isOnPoint || !session.canAddPoint
                ? "Drag to aim the whole clip."
                : "Drag to aim the whole clip. To follow the play, tap Add Point here and drag."
        }
        if session.isOnPoint { return "Drag to move this point's aim. The frame glides between points." }
        if session.isAtPointLimit { return "Up to \(AimTrack.manualLimit) points. Tap a point to change or delete it." }
        return "The frame glides between points. Drag to aim here, then tap Add Point."
    }

    private var preview: some View {
        let ratio = session.sourceSize.map { $0.width / max($0.height, 1) } ?? 16.0 / 9
        return GeometryReader { geometry in
            let size = geometry.size
            let window = session.framingWindow
            let rect = CGRect(x: window.minX * size.width, y: window.minY * size.height,
                              width: window.width * size.width, height: window.height * size.height)
            ZStack {
                PlayerSurface(player: session.preview.player)
                // Outside the window is dimmed: it won't be in the video.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { path in path.addRect(rect) }
                    .stroke(windowColor, style: StrokeStyle(lineWidth: 2, dash: session.draft != nil ? [8, 6] : []))
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
                    .onEnded { _ in
                        applied = .zero
                        session.endMove()
                    }
            )
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Vertical frame over the clip. Drag to aim.")
    }

    /// Yellow on a point (what a drag changes), white while gliding between points.
    private var windowColor: Color {
        session.aimKeys.count > 1 && session.isOnPoint && session.draft == nil ? .yellow : .white
    }
}

/// The clip's timeline: drag to scrub; aim points as marks to tap (go to it) or drag (move it in time).
private struct AimTimelineBar: View {
    let session: ClipExportSession
    /// Height of the touch area; the track itself is thinner.
    private let height: CGFloat = 44
    private let markSize: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            // Inset by half a mark, so marks at the very start and end show whole.
            let inset = markSize / 2
            let width = max(geometry.size.width - markSize, 1)
            let duration = max(session.preview.duration, 0.001)
            let x = { (time: Double) in inset + CGFloat(min(max(time / duration, 0), 1)) * width }
            let time = { (x: CGFloat) in Double((x - inset) / width) * duration }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 6)
                    .padding(.horizontal, inset)
                Capsule().fill(Color.accentColor.opacity(0.6))
                    .frame(width: x(session.preview.currentTime) - inset, height: 6)
                    .padding(.leading, inset)
                ForEach(Array(session.aimKeys.enumerated()), id: \.offset) { index, key in
                    mark(index: index, time: key.time, toTime: time)
                        .position(x: x(key.time), y: height / 2)
                }
                Rectangle().fill(Color.primary).frame(width: 2, height: height - 8)
                    .position(x: x(session.preview.currentTime), y: height / 2)
                    .allowsHitTesting(false)
            }
            .frame(height: height)
            .coordinateSpace(name: "aimTimeline")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in session.seek(to: time(value.location.x)) }
            )
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    /// `toTime` turns a position on the bar into seconds.
    private func mark(index: Int, time: Double, toTime: @escaping (CGFloat) -> Double) -> some View {
        let isSelected = session.aimKeys.count > 1 && session.selectedPoint == index && session.isOnPoint
        return Diamond()
            .fill(isSelected ? Color.yellow : Color.white)
            .overlay(Diamond().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: markSize, height: markSize)
            // A bigger invisible target than the mark itself.
            .frame(width: 36, height: height)
            .contentShape(Rectangle())
            .onTapGesture { session.selectPoint(index) }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("aimTimeline"))
                    .onChanged { value in session.movePoint(index, to: toTime(value.location.x)) }
                    .onEnded { _ in session.endMove() }
            )
            .accessibilityElement()
            .accessibilityLabel("Point at \(Format.duration(time))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.selectPoint(index) }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
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
