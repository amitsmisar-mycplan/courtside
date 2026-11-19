import SwiftData
import SwiftUI

/// Live recording from a tripod. The whole screen marks; on the dimmed screen the first touch only
/// wakes it (decision 0035). Stop is a tap; Record Part N afterwards continues the same game.
/// Opened from a game, or recorded again after a stop, the recording is that game's next part.
struct RecordingView: View {
    let modelContext: ModelContext
    /// The game to add a part to; nil records a new game.
    var game: Game? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var controller: CaptureSessionController?
    @State private var session: RecordingSession?
    @State private var isTouching = false
    @State private var flashOpacity = 0.0
    @State private var showProcessing = false
    @State private var savedBrightness: CGFloat?
    @State private var haptics = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session, let controller {
                content(session, controller)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .lockedOrientation(.landscape)
        .task {
            guard session == nil else { return }
            let controller = CaptureSessionController()
            let session = RecordingSession(service: controller, context: modelContext, game: game)
            self.controller = controller
            self.session = session
            // The touch that opened this screen mustn't land as a mark.
            session.ignoreTapsBriefly()
            await session.prepare(preflight: RecordingPreflight.current())
            updateScreenAwake()
        }
        .onDisappear {
            ScreenAwake.shared.release(.recording)
            restoreBrightness()
            session?.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            updateScreenAwake()
            if phase == .active { session?.ignoreTapsBriefly() }
            if phase == .background { Task { await session?.handleBackground() } }
        }
        .onChange(of: session?.isDimmed ?? false) { _, dimmed in
            // Near-black screen saves meaningful battery over a 90-minute game.
            if dimmed { lowerBrightness() } else { restoreBrightness() }
        }
        .onChange(of: session?.phase) { _, phase in
            updateScreenAwake()
            if phase == .finished { restoreBrightness() }
        }
        .fullScreenCover(isPresented: $showProcessing, onDismiss: { dismiss() }) {
            if let game = session?.game {
                ProcessingView(game: game, modelContext: modelContext)
            }
        }
    }

    @ViewBuilder
    private func content(_ session: RecordingSession, _ controller: CaptureSessionController) -> some View {
        switch session.phase {
        case .preparing:
            ProgressView("Starting camera…")
                .tint(.white)
                .foregroundStyle(.white)
        case .failed(let message):
            failure(message, needsSettings: session.failureNeedsSettings)
        case .ready, .recording, .finishing:
            CameraPreview(source: controller)
                .ignoresSafeArea()
            if session.phase == .ready {
                readyOverlay(session)
            } else {
                recordingOverlay(session)
            }
        case .finished:
            finished(session)
        }
    }

    /// Auto-lock stays off while the camera is up (waiting to start, recording, saving) and the app
    /// is in front; it comes back when recording ends, the screen closes, or the app leaves.
    private func updateScreenAwake() {
        let phase = session?.phase
        let cameraUp = phase == .ready || phase == .recording || phase == .finishing
        ScreenAwake.shared.set(.recording, awake: cameraUp && scenePhase == .active)
    }

    // MARK: Before recording

    private func readyOverlay(_ session: RecordingSession) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                Button("Close") { dismiss() }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                Spacer()
                if !session.preflightIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.preflightIssues) { issue in
                            Label(issue.message, systemImage: issue.blocksRecording ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(issue.blocksRecording ? .red : .yellow)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Spacer()
            if session.availableLenses.count > 1 {
                LensPicker(
                    lenses: session.availableLenses,
                    selection: session.lens,
                    isEnabled: session.canChooseLens
                ) { lens in
                    Task { await session.selectLens(lens) }
                }
            }
            Button {
                Task { await session.start() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(session.canStart ? Color.red : Color.gray, in: Capsule())
            }
            .disabled(!session.canStart)
            Text("Mount the phone on a tripod, then tap anywhere during the game when something good happens.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    // MARK: Recording

    private func recordingOverlay(_ session: RecordingSession) -> some View {
        ZStack {
            // The whole screen marks, on touch-down for timing accuracy.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isTouching else { return }
                            isTouching = true
                            screenTouched(session)
                        }
                        .onEnded { _ in isTouching = false }
                )

            Rectangle()
                .strokeBorder(.white, lineWidth: 16)
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if session.isDimmed {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                dimmedStatus(session)
            } else {
                controls(session)
            }

            if session.phase == .finishing {
                ProgressView("Saving…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func controls(_ session: RecordingSession) -> some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    session.refocus()
                } label: {
                    Label("Refocus", systemImage: "scope")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 14) {
                        Label(Format.duration(session.elapsed), systemImage: "record.circle.fill")
                            .labelStyle(RedDotLabelStyle())
                        Label("\(session.markCount)", systemImage: "flag.fill")
                        // The lens is fixed once recording starts; shown, not changeable.
                        if let lens = session.lens {
                            Text(lens.label)
                                .accessibilityLabel("\(lens.spokenName), locked while recording")
                        }
                    }
                    .font(.title3.weight(.bold).monospacedDigit())
                    if let warning = session.thermalWarning {
                        Label(warning, systemImage: "thermometer.high")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
            Spacer()
            HStack(alignment: .bottom) {
                if session.canUndo {
                    Button {
                        session.undoLastMark()
                    } label: {
                        Label(session.undo.ids.count > 1 ? "Undo \(session.undo.ids.count)" : "Undo", systemImage: "arrow.uturn.backward")
                            .monospacedDigit()
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                }
                Spacer()
                StopButton {
                    Task { await session.stop() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    /// Still clearly recording while the screen saves battery: red dot, time and marks, bright
    /// enough to read at the lowered brightness, and no buttons (decision 0035).
    private func dimmedStatus(_ session: RecordingSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(.red)
                    .frame(width: 22, height: 22)
                Text(Format.duration(session.elapsed))
                    .font(.system(size: 48, weight: .bold).monospacedDigit())
            }
            Label("\(session.markCount)", systemImage: "flag.fill")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text("Recording · touch to wake")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Format.duration(session.elapsed)), \(session.markCount) \(session.markCount == 1 ? "mark" : "marks"). Touch to wake.")
        .allowsHitTesting(false)
    }

    private func screenTouched(_ session: RecordingSession) {
        guard session.screenTouched() == .marked else { return }
        haptics.impactOccurred()
        haptics.prepare()
        flashOpacity = 1
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
    }

    // MARK: After recording

    private func finished(_ session: RecordingSession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Saved \(Format.duration(session.elapsed)) · \(session.markCount) \(session.markCount == 1 ? "mark" : "marks")")
                .font(.title2.weight(.semibold))
            if let note = session.endNote {
                Text(note)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 12) {
                if let game = session.game {
                    // First: the way back after a stop by mistake. The next recording goes into the
                    // same game as its next part.
                    Button {
                        session.recordAgain()
                    } label: {
                        Label("Record Part \(game.nextPartIndex + 1)", systemImage: "record.circle")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                if session.markCount > 0 {
                    Button {
                        showProcessing = true
                    } label: {
                        Label("Make \(session.markCount) \(session.markCount == 1 ? "Clip" : "Clips")", systemImage: "scissors")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    private func failure(_ message: String, needsSettings: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                if needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    // MARK: Brightness

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    private func lowerBrightness() {
        guard let screen, savedBrightness == nil else { return }
        savedBrightness = screen.brightness
        screen.brightness = 0.05
    }

    private func restoreBrightness() {
        guard let savedBrightness else { return }
        screen?.brightness = savedBrightness
        self.savedBrightness = nil
    }
}

/// 0.5× / 1×, like the Camera app. Shown only before recording, on phones with both lenses.
private struct LensPicker: View {
    let lenses: [CameraLens]
    let selection: CameraLens?
    let isEnabled: Bool
    let onSelect: (CameraLens) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(lenses, id: \.self) { lens in
                let isSelected = lens == selection
                Button {
                    onSelect(lens)
                } label: {
                    Text(lens.label)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? .yellow : .white)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.black.opacity(isSelected ? 0.75 : 0.45), in: Circle())
                }
                .accessibilityLabel(lens.spokenName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
        .disabled(!isEnabled)
    }
}

/// Stops the recording with one tap (decision 0035). It's hidden while the screen is dimmed, so a
/// touch on the dark screen can't stop anything; a stop by mistake is undone with Record Part N.
private struct StopButton: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.4), lineWidth: 4)
                RoundedRectangle(cornerRadius: 6)
                    .fill(.red)
                    .frame(width: 26, height: 26)
            }
            .frame(width: 68, height: 68)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Stops and saves. You can record the next part right after.")
    }
}

private struct RedDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.red)
            configuration.title
        }
    }
}
