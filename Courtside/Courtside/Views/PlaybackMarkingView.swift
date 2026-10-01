import SwiftData
import SwiftUI

/// Full-screen game playback where the whole screen, except the control strip, is the mark button.
struct PlaybackMarkingView: View {
    let game: Game
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    /// Regular in portrait on iPhone, compact in landscape.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var session: MarkingSession?
    @State private var flashOpacity = 0.0
    @State private var isTouching = false
    @State private var haptics = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                PlayerSurface(player: session.player)
                    .ignoresSafeArea()

                // Marks on touch-down, not touch-up, so the offset is as close to the moment as possible.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isTouching else { return }
                                isTouching = true
                                placeMark(in: session)
                            }
                            .onEnded { _ in isTouching = false }
                    )

                Rectangle()
                    .strokeBorder(.white, lineWidth: 16)
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack {
                    topBar(session)
                    Spacer()
                    controlStrip(session)
                }
                .padding(12)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Either orientation: the parent turns the phone to match the video (decision 0008).
        .lockedOrientation(.allButUpsideDown)
        .onAppear {
            if session == nil {
                session = MarkingSession(game: game, context: modelContext)
            }
            haptics.prepare()
            UIApplication.shared.isIdleTimerDisabled = true
            session?.player.play()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session?.tearDown()
        }
    }

    private func placeMark(in session: MarkingSession) {
        guard session.placeMark() else { return }
        haptics.impactOccurred()
        haptics.prepare()
        flashOpacity = 1
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
    }

    private func topBar(_ session: MarkingSession) -> some View {
        HStack(alignment: .top) {
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
                .transition(.opacity)
            }
            Spacer()
            Label("\(session.markCount)", systemImage: "flag.fill")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: session.undoableMark != nil)
    }

    private func controlStrip(_ session: MarkingSession) -> some View {
        Group {
            if verticalSizeClass == .regular {
                // Portrait: too narrow for one row, so the scrub bar gets its own.
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        timeLabel(session.currentTime)
                        MarkScrubBar(session: session)
                        timeLabel(session.duration)
                    }
                    HStack {
                        doneButton
                        Spacer()
                        jumpBackButton(session)
                        Spacer()
                        playPauseButton(session)
                        Spacer()
                        speedButton(session)
                    }
                }
            } else {
                HStack(spacing: 18) {
                    doneButton
                    jumpBackButton(session)
                    playPauseButton(session)
                    timeLabel(session.currentTime)
                    MarkScrubBar(session: session)
                    timeLabel(session.duration)
                    speedButton(session)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        // Swallow taps on the strip's background so they don't place marks.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var doneButton: some View {
        Button("Done") {
            // Rotate back first so the screen underneath never lays out in landscape.
            OrientationLock.set(.portrait)
            dismiss()
        }
        .font(.headline)
    }

    private func jumpBackButton(_ session: MarkingSession) -> some View {
        Button("Back 10 seconds", systemImage: "gobackward.10") { session.jumpBack() }
            .labelStyle(.iconOnly)
    }

    private func playPauseButton(_ session: MarkingSession) -> some View {
        Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
            session.togglePlayback()
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .frame(width: 32)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(Format.duration(seconds))
            .monospacedDigit()
            .font(.caption)
    }

    private func speedButton(_ session: MarkingSession) -> some View {
        Button {
            session.cycleSpeed()
        } label: {
            Text(session.speed == 1.5 ? "1.5×" : "\(Int(session.speed))×")
                .font(.headline.monospacedDigit())
                .frame(width: 44)
                .padding(.vertical, 4)
                .background(.white.opacity(0.2), in: Capsule())
        }
    }
}

/// Scrub bar with a lane of mark ticks above it. Tapping a tick seeks to that mark.
private struct MarkScrubBar: View {
    let session: MarkingSession

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(session.duration, 0.001)
            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    Color.clear
                    ForEach(session.ticks) { tick in
                        Capsule()
                            .fill(.yellow)
                            .frame(width: 3, height: 14)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { session.seek(to: tick.offset) }
                            .offset(x: width * tick.offset / duration - 11)
                    }
                }
                .frame(height: 22)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                    Capsule().fill(.white).frame(width: width * session.currentTime / duration, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .offset(x: width * session.currentTime / duration - 7)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            session.scrub(to: duration * min(max(value.location.x / width, 0), 1))
                        }
                        .onEnded { value in
                            session.seek(to: duration * min(max(value.location.x / width, 0), 1))
                        }
                )
            }
        }
        .frame(height: 46)
    }
}
