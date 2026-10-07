import SwiftData
import SwiftUI

/// Live recording from a tripod. The whole screen marks; stopping takes a deliberate 1-second hold.
struct RecordingView: View {
    let modelContext: ModelContext

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
            let session = RecordingSession(service: controller, context: modelContext)
            self.controller = controller
            self.session = session
            await session.prepare(preflight: RecordingPreflight.current())
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            restoreBrightness()
            session?.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await session?.handleBackground() } }
        }
        .onChange(of: session?.isDimmed ?? false) { _, dimmed in
            // Near-black screen saves meaningful battery over a 90-minute game.
            if dimmed { lowerBrightness() } else { restoreBrightness() }
        }
        .onChange(of: session?.phase) { _, phase in
            if phase == .finished {
                UIApplication.shared.isIdleTimerDisabled = false
                restoreBrightness()
            }
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
                            placeMark(session)
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
                Text(Format.duration(session.elapsed))
                    .font(.system(size: 40, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
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
                if session.undoableMark != nil {
                    Button {
                        session.undoLastMark()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                }
                Spacer()
                HoldToStopButton {
                    Task { await session.stop() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private func placeMark(_ session: RecordingSession) {
        let wasDimmed = session.isDimmed
        guard session.placeMark() else { return }
        haptics.impactOccurred()
        haptics.prepare()
        // No flash while the screen was dark — keep it dark and quiet.
        guard !wasDimmed else { return }
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
                if session.markCount > 0 {
                    Button {
                        showProcessing = true
                    } label: {
                        Label("Make \(session.markCount) \(session.markCount == 1 ? "Clip" : "Clips")", systemImage: "scissors")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
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

/// Stopping a game recording takes a deliberate 1-second hold, so a stray tap can't end it.
private struct HoldToStopButton: View {
    let onStop: () -> Void
    @State private var isPressing = false
    @State private var showHint = false

    var body: some View {
        VStack(spacing: 6) {
            if showHint {
                Text("Hold to stop")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.4), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: isPressing ? 1 : 0)
                    .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(isPressing ? .linear(duration: 1) : .easeOut(duration: 0.2), value: isPressing)
                RoundedRectangle(cornerRadius: 6)
                    .fill(.red)
                    .frame(width: 26, height: 26)
            }
            .frame(width: 68, height: 68)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 1) {
                onStop()
            } onPressingChanged: { pressing in
                isPressing = pressing
                if pressing { showHint = true }
            }
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Touch and hold for one second")
        }
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
