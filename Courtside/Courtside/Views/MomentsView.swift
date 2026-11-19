import SwiftData
import SwiftUI

/// "Find Moments" for one part (decision 0029): listens for the crowd, then lists what it found.
/// Each suggestion plays its clip window from the part's video; Accept adds an ordinary mark.
struct MomentsView: View {
    @State private var session: MomentReviewSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let title: String

    init(part: GamePart, modelContext: ModelContext) {
        _session = State(initialValue: MomentReviewSession(part: part, context: modelContext))
        title = (part.game?.hasSeveralParts ?? false) ? "Find Moments · \(part.title)" : "Find Moments"
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // Upright first, so the game page never lays out sideways.
                            OrientationLock.set(.portrait)
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(session.finder.phase == .running)
        .onAppear {
            ScreenAwake.shared.hold(.findMoments)
            session.appear()
        }
        .onDisappear {
            ScreenAwake.shared.release(.findMoments)
            session.close()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.resumeIfInterrupted() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.finder.phase {
        case .running, .interrupted:
            listening
        case .failed(let message):
            notice(icon: "speaker.slash", title: "Couldn't find moments", detail: message, retry: true)
        case .cancelled where !session.hasResults:
            notice(icon: "pause.circle", title: "Stopped",
                   detail: "What Courtside heard so far is kept. Find Moments again to pick up where it stopped.", retry: true)
        default:
            if session.hasResults { results } else { listening }
        }
    }

    // MARK: Listening

    private var listening: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: session.finder.phase == .running)
            Text(session.finder.phase == .interrupted ? "Paused" : "Listening for the crowd")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ProgressView(value: session.finder.progress)
                Text(progressText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(session.finder.phase == .interrupted
                 ? "Courtside was in the background too long. It carries on when you come back."
                 : "Cheering and applause usually follow a good play. This runs on your iPhone; the sound isn't kept or sent anywhere. Keep Courtside open until it finishes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(role: .cancel) {
                session.stop()
            } label: {
                Text("Stop").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(24)
    }

    private var progressText: String {
        let total = session.part.durationSeconds
        return "\(Format.duration(session.finder.progress * total)) of \(Format.duration(total))"
    }

    private func notice(icon: String, title: String, detail: String, retry: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        } actions: {
            if retry {
                Button("Find Moments") { session.find() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Results

    /// Full screen (decision 0031): sideways (the phone turned, or a wide video's preview tapped), or
    /// a portrait video's preview tapped, which stays upright.
    @State private var fullScreenRequested = false
    private var isFullScreen: Bool { verticalSizeClass == .compact || fullScreenRequested }

    @ViewBuilder
    private var results: some View {
        // A stable container, so switching layouts doesn't re-run the orientation lock.
        ZStack {
            if session.moments.isEmpty {
                ContentUnavailableView {
                    Label("Nothing stood out", systemImage: "waveform.slash")
                } description: {
                    Text("The crowd didn't react much louder anywhere in this video than it did the rest of the time. You can still watch it and mark plays yourself.")
                }
            } else if isFullScreen {
                fullScreen
            } else {
                reviewList
            }
        }
        .lockedOrientation(.allButUpsideDown)
    }

    private var reviewList: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Wide footage is zoomed to fill a taller box and loses its left and right edges
                // here; full screen shows all of it. Portrait footage fits whole.
                player
                    .frame(height: geometry.size.height * (typeSize.isAccessibilitySize ? 0.3 : 0.45))
                List {
                    Section {
                        ForEach(session.visibleMoments) { moment in
                            MomentRow(
                                moment: moment,
                                isSelected: moment.id == session.selectedID,
                                select: { session.select(moment) },
                                accept: { decide(moment) { session.accept(moment) } },
                                dismiss: { decide(moment) { session.dismiss(moment) } },
                                undo: { withAnimation { session.undo(moment) } }
                            )
                            .listRowBackground(moment.id == session.selectedID ? Color.accentColor.opacity(0.12) : nil)
                        }
                        if session.pendingCount == 0 && !session.showsReviewed {
                            allReviewed
                        }
                    } header: {
                        Text(summary)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tap a moment to watch it, or turn your phone sideways. Accept adds a mark there, and its clip is made like any other: \(Int(ClipSettings.preRoll)) seconds before, \(Int(ClipSettings.postRoll)) after.")
                            if session.reviewedCount > 0 {
                                Button(session.showsReviewed ? "Hide Reviewed" : "Show \(session.reviewedCount) Reviewed") {
                                    withAnimation { session.showsReviewed.toggle() }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .bottom) { undoBar }
            }
        }
    }

    private var allReviewed: some View {
        VStack(spacing: 4) {
            Label("All reviewed", systemImage: "checkmark.circle")
                .font(.headline)
            Text(session.acceptedCount == 0
                 ? "Nothing added. Tap Done to go back."
                 : "Tap Done to make the clips.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Accept or Dismiss: the row shows its new state for a moment, then fades out of the list.
    private func decide(_ moment: SuggestedMoment, _ action: () -> Void) {
        withAnimation { action() }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeOut(duration: 0.35)) { session.finishLeaving(moment) }
        }
    }

    /// The last decision, with Undo, for a few seconds.
    @ViewBuilder
    private var undoBar: some View {
        if let last = session.lastDecision {
            HStack(spacing: 12) {
                Image(systemName: last.status == .accepted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(last.status == .accepted ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text("\(last.status == .accepted ? "Added" : "Dismissed") \(Format.duration(last.seconds))")
                    .font(.subheadline.monospacedDigit())
                Spacer(minLength: 8)
                if last.canUndo {
                    Button("Undo") { withAnimation { session.undoLast() } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: last.id) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation { session.forgetLastDecision() }
            }
        }
    }

    private var player: some View {
        PlayerSurface(player: session.preview.player,
                      videoGravity: session.preview.isPortrait ? .resizeAspect : .resizeAspectFill)
            .frame(maxWidth: .infinity)
            .clipped()
            // A view, not a colour: a colour background would run up under the navigation bar.
            .background { Color.black }
            .contentShape(Rectangle())
            .onTapGesture(perform: enterFullScreen)
            .overlay {
                if session.preview.playbackFailed {
                    PlaybackFailedNotice(subject: "video")
                } else if session.selected == nil {
                    Text(session.pendingCount == 0 ? "All reviewed" : "Tap a moment to watch it")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .overlay(alignment: .topLeading) {
                if let selected = session.selected {
                    timeBadge(selected)
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if session.selected != nil {
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: enterFullScreen)
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(8)
                }
            }
    }

    private func timeBadge(_ moment: SuggestedMoment) -> some View {
        Text(Format.duration(moment.seconds))
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }

    /// Wide video turns the screen sideways; portrait video fills the screen upright.
    private func enterFullScreen() {
        guard session.selected != nil else { return }
        if session.preview.isPortrait {
            fullScreenRequested = true
        } else {
            OrientationLock.set(.landscape)
        }
    }

    /// Back to the list: upright first, then free to turn again.
    private func exitFullScreen() {
        fullScreenRequested = false
        OrientationLock.set(.portrait)
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            OrientationLock.set(.allButUpsideDown)
        }
    }

    // MARK: Full screen

    /// The whole moment, as large as it fits, with the same decisions as the list.
    private var fullScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: session.preview.player)
                .ignoresSafeArea()
            if session.preview.playbackFailed {
                PlaybackFailedNotice(subject: "video")
            } else if session.selected == nil {
                // Nothing left to decide: dim the last frame and offer the way back.
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 16) {
                    Label(session.pendingCount == 0 ? "All reviewed" : "Choose a moment",
                          systemImage: session.pendingCount == 0 ? "checkmark.circle" : "list.bullet")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Button("Back to List", action: exitFullScreen)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            if session.canStep {
                HStack {
                    stepButton("Previous Moment", systemImage: "chevron.left", action: session.selectPrevious)
                    Spacer()
                    stepButton("Next Moment", systemImage: "chevron.right", action: session.selectNext)
                }
                .padding(.horizontal, 8)
            }
        }
        .overlay(alignment: .top) {
            HStack(alignment: .top) {
                if let selected = session.selected {
                    HStack(spacing: 8) {
                        timeBadge(selected)
                        Text(selected.sound.caption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                Spacer()
                Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left", action: exitFullScreen)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .overlay(alignment: .top) {
            undoBar
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .overlay(alignment: .bottom) {
            if let selected = session.selected {
                fullScreenControls(selected)
                    .padding(.bottom, 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func stepButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.black.opacity(0.45), in: Circle())
    }

    @ViewBuilder
    private func fullScreenControls(_ moment: SuggestedMoment) -> some View {
        HStack(spacing: 12) {
            switch moment.status {
            case .pending:
                Button("Dismiss", systemImage: "xmark") { withAnimation { session.dismiss(moment) } }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Accept", systemImage: "checkmark") { withAnimation { session.accept(moment) } }
                    .buttonStyle(.borderedProminent)
            case .accepted, .dismissed:
                Label(moment.status == .accepted ? "Added" : "Dismissed",
                      systemImage: moment.status == .accepted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(.white)
                if moment.canUndo {
                    Button("Undo") { withAnimation { session.undo(moment) } }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .padding(8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var summary: String {
        let pending = session.pendingCount
        let added = session.acceptedCount
        let review = pending == 1 ? "1 to review" : "\(pending) to review"
        if pending == 0 { return added > 0 ? "\(added) added" : "Nothing added" }
        return added > 0 ? "\(review) · \(added) added" : review
    }
}

/// One suggestion: when, what was heard, and Accept / Dismiss (or its outcome, with Undo).
private struct MomentRow: View {
    let moment: SuggestedMoment
    let isSelected: Bool
    let select: () -> Void
    let accept: () -> Void
    let dismiss: () -> Void
    let undo: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                details
                Spacer(minLength: 8)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                details
                controls
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityAction(named: "Watch", select)
    }

    private var details: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "play.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.duration(moment.seconds))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(moment.status == .dismissed ? .secondary : .primary)
                Text(moment.sound.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Label("Dismiss", systemImage: "xmark").lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    private var acceptButton: some View {
        Button(action: accept) {
            Label("Accept", systemImage: "checkmark").lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var controls: some View {
        switch moment.status {
        case .pending:
            // Side by side, or (largest text) stacked full width so neither label breaks.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    dismissButton
                    acceptButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    dismissButton.frame(maxWidth: .infinity)
                    acceptButton.frame(maxWidth: .infinity)
                }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        case .accepted, .dismissed:
            HStack(spacing: 8) {
                if moment.status == .accepted {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Dismissed").foregroundStyle(.secondary)
                }
                if moment.canUndo {
                    Button("Undo", action: undo)
                        .buttonStyle(.borderless)
                }
            }
            .font(.subheadline)
        }
    }

}

extension SuggestedMoment.Sound {
    var caption: String {
        switch self {
        case .cheering: "Cheering"
        case .applause: "Applause"
        case .shouting: "Shouting"
        case .crowd: "Crowd noise"
        case .loud: "Loud moment"
        }
    }
}
