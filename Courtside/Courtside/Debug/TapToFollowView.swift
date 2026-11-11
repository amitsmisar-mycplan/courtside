#if DEBUG
import SwiftData
import SwiftUI

/// Debug-only list of clips for the tap-to-follow spike (decision 0027). Reached from Settings →
/// Debug in debug builds; compiled out of release builds.
struct TapToFollowListView: View {
    @Query(sort: \Clip.createdAt, order: .reverse) private var clips: [Clip]
    @State private var mode = FollowMode.trackerWithResnap
    @State private var summary = FollowSummary([])
    @State private var logExists = false

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(FollowMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let rate = summary.rate {
                    LabeledContent("Stayed on player", value: "\(summary.stayed) of \(summary.clips) clips (\(Int((rate * 100).rounded()))\u{00A0}%)")
                } else {
                    Text("No results yet. Goal: the box stays on the right player for the whole clip on at least 70\u{00A0}% of clips.")
                        .foregroundStyle(.secondary)
                }
                if logExists {
                    ShareLink("Share results log", item: TapToFollowLog.standard.url)
                }
            } header: {
                Text("Tap-to-follow experiment")
            } footer: {
                Text("Debug builds only. Pick a clip, tap your player on the first frame, then judge the whole clip. Nothing is exported or changed.")
            }
            Section("Clips") {
                if clips.isEmpty { Text("No clips yet.").foregroundStyle(.secondary) }
                ForEach(clips) { clip in
                    NavigationLink {
                        TapToFollowScreen(clip: clip, mode: mode)
                    } label: {
                        ClipRow(clip: clip, result: summary.latest[clip.id])
                    }
                }
            }
        }
        .navigationTitle("Tap to follow")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        summary = FollowSummary(TapToFollowLog.standard.verdicts())
        logExists = TapToFollowLog.standard.exists
    }

    private struct ClipRow: View {
        let clip: Clip
        let result: FollowVerdict.Result?

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Text(clip.game?.displayTitle ?? "Clip")
                    Text("\(clip.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Int(clip.window.duration.rounded())) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch result {
                case .stayed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Stayed")
                case .lost: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Lost")
                case nil: EmptyView()
                }
            }
        }
    }
}

/// One clip: tap the player, track, watch, judge.
private struct TapToFollowScreen: View {
    @State private var session: TapToFollowSession
    @State private var showCrop = false

    init(clip: Clip, mode: FollowMode) {
        _session = State(initialValue: TapToFollowSession(clipID: clip.id, clipURL: clip.fileURL, clipSeconds: clip.window.duration, mode: mode))
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                picture
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    controls.padding(.horizontal)
                }
                .frame(maxWidth: wide ? 320 : .infinity, maxHeight: wide ? .infinity : proxy.size.height * 0.45)
            }
        }
        .navigationTitle("Tap to follow")
        .navigationBarTitleDisplayMode(.inline)
        .lockedOrientation(.allButUpsideDown)
        .task { await session.load() }
        .onDisappear { session.stop() }
    }

    // MARK: Picture

    @ViewBuilder private var picture: some View {
        switch session.phase {
        case .loading:
            ProgressView("Finding people…")
        case .choosing, .tracking:
            if let image = session.firstFrame {
                FrameOverlay(size: session.displaySize) {
                    Image(decorative: image, scale: 1).resizable()
                } overlay: { rect in
                    ForEach(Array(session.people.enumerated()), id: \.offset) { _, person in
                        BoxShape(box: person, in: rect).stroke(.white.opacity(0.6), lineWidth: 1)
                    }
                    if let box = session.chosenBox {
                        BoxShape(box: box, in: rect).stroke(.yellow, lineWidth: 3)
                    }
                } onTap: { session.tap(at: $0) }
            }
        case .review:
            if showCrop, let window = session.currentCropWindow {
                CropPreview(player: session.playback, displaySize: session.displaySize, window: window)
            } else {
                FrameOverlay(size: session.displaySize) {
                    PlayerSurface(player: session.playback.player)
                } overlay: { rect in
                    if let sample = session.currentSample {
                        BoxShape(box: sample.box, in: rect).stroke(color(for: sample), lineWidth: 3)
                    }
                } onTap: { _ in session.togglePause() }
            }
        case .failed(let message):
            ContentUnavailableView("Couldn't track", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private func color(for sample: FollowSample) -> Color {
        if sample.resnapped { return .cyan }
        return sample.confidence >= 0.5 ? .green : sample.confidence >= 0.3 ? .yellow : .red
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.phase {
            case .loading, .failed:
                EmptyView()
            case .choosing:
                Text(session.people.isEmpty
                     ? "No people found in the first frame. Tap your player anyway; a default-size box is used."
                     : "Tap your player. White boxes are the people Vision found; yellow is your pick.")
                    .font(.callout)
                Picker("Mode", selection: $session.mode) {
                    ForEach(FollowMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if session.chosenBox != nil, !session.snappedToBody {
                    Text("Not on a detected person: using a default-size box.").font(.caption).foregroundStyle(.orange)
                }
                Button("Track") { session.startTracking() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.chosenBox == nil)
            case .tracking:
                ProgressView(value: session.progress) { Text("Tracking…") }
            case .review:
                review
            }
        }
        .padding(.vertical)
    }

    @ViewBuilder private var review: some View {
        if let track = session.track {
            Picker("View", selection: $showCrop) {
                Text("Box").tag(false)
                Text("9:16 follow").tag(true)
            }
            .pickerStyle(.segmented)
            Text(stats(track)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Green: tracker sure. Yellow/red: unsure. Cyan: re-snapped to a detected body. Tap the video to pause.")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("Scene", selection: $session.scene) {
                ForEach(FollowVerdict.Scene.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("If lost: what happened?", text: $session.failureNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Menu("Common failures") {
                ForEach(Self.commonFailures, id: \.self) { note in
                    Button(note) { session.failureNote = note }
                }
            }
            HStack {
                Button("Stayed on my player") { session.record(.stayed) }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button("Lost or switched") { session.record(.lost) }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            if let saved = session.savedResult {
                Label(saved == .stayed ? "Logged: stayed" : "Logged: lost", systemImage: "checkmark")
                    .font(.callout)
            }
            if let error = session.saveError {
                Text("Couldn't log: \(error)").font(.caption).foregroundStyle(.red)
            }
            Button("Tap again") { session.chooseAgain() }
        }
    }

    private func stats(_ track: FollowTrack) -> String {
        String(format: "%@ · %.1f s for %.1f s of video (%.2f× real time) · %d frames at %.0f fps · %d re-snaps · %d restarts · %d unsure frames · min confidence %.2f",
               track.mode.title, track.processingSeconds, track.videoSeconds, track.processingSeconds / max(track.videoSeconds, 0.001),
               track.samples.count, track.trackedFPS, track.resnaps, track.restarts, track.lowConfidenceFrames, track.minConfidence)
    }

    static let commonFailures = [
        "Switched to a player who crossed in front",
        "Lost in a crowd under the basket",
        "Box drifted onto the floor or background",
        "Box grew or shrank to cover several players",
        "Lost when the player left the frame",
        "Wrong player from the first frame",
    ]
}

/// Fits content of `size` in the available space and gives the overlay the fitted rect. Taps are
/// reported normalized to the content, origin top left.
private struct FrameOverlay<Content: View, Overlay: View>: View {
    let size: CGSize
    @ViewBuilder let content: () -> Content
    @ViewBuilder let overlay: (CGRect) -> Overlay
    let onTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            let rect = FollowCrop.fitted(size, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                content()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                overlay(rect)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard rect.contains(location) else { return }
                onTap(CGPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height))
            }
        }
    }
}

private struct BoxShape: Shape {
    let box: CGRect
    let frame: CGRect

    init(box: CGRect, in frame: CGRect) {
        self.box = box
        self.frame = frame
    }

    func path(in _: CGRect) -> Path {
        Path(CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height,
                    width: box.width * frame.width, height: box.height * frame.height))
    }
}

/// The 9:16 window of the playing clip: the video drawn at full height, shifted and clipped.
private struct CropPreview: View {
    let player: LoopingClipPlayer
    let displaySize: CGSize
    let window: CGRect

    var body: some View {
        GeometryReader { proxy in
            let frame = FollowCrop.fitted(CGSize(width: 9, height: 16), in: proxy.size)
            let videoWidth = frame.height * displaySize.width / max(displaySize.height, 1)
            ZStack(alignment: .topLeading) {
                Color.black
                ZStack(alignment: .topLeading) {
                    PlayerSurface(player: player.player)
                        .frame(width: videoWidth, height: frame.height)
                        .offset(x: -window.minX * videoWidth)
                        .animation(nil, value: window)
                }
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
                .offset(x: frame.minX, y: frame.minY)
            }
        }
    }
}
#endif
