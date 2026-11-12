import SwiftData
import SwiftUI

/// "Find Moments" for one part (decision 0029): listens for the crowd, then lists what it found.
/// Each suggestion plays its clip window from the part's video; Accept adds an ordinary mark.
struct MomentsView: View {
    @State private var session: MomentReviewSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

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
                        Button("Done") { dismiss() }
                    }
                }
        }
        .interactiveDismissDisabled(session.finder.phase == .running)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.appear()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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

    @ViewBuilder
    private var results: some View {
        let moments = session.moments
        if moments.isEmpty {
            ContentUnavailableView {
                Label("Nothing stood out", systemImage: "waveform.slash")
            } description: {
                Text("The crowd didn't react much louder anywhere in this video than it did the rest of the time. You can still watch it and mark plays yourself.")
            }
        } else {
            VStack(spacing: 0) {
                player
                List {
                    Section {
                        ForEach(moments) { moment in
                            MomentRow(
                                moment: moment,
                                isSelected: moment.id == session.selectedID,
                                select: { session.select(moment) },
                                accept: { session.accept(moment) },
                                dismiss: { session.dismiss(moment) },
                                undo: { session.undo(moment) }
                            )
                            .listRowBackground(moment.id == session.selectedID ? Color.accentColor.opacity(0.12) : nil)
                        }
                    } header: {
                        Text(summary)
                    } footer: {
                        Text("Tap a moment to watch it. Accept adds a mark there, and its clip is made like any other: \(Int(ClipSettings.preRoll)) seconds before, \(Int(ClipSettings.postRoll)) after.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var player: some View {
        PlayerSurface(player: session.preview.player)
            .aspectRatio(16 / 9, contentMode: .fit)
            // Large text needs the room for the list.
            .frame(maxWidth: .infinity, maxHeight: typeSize.isAccessibilitySize ? 160 : 280)
            // A view, not a colour: a colour background would run up under the navigation bar.
            .background { Color.black }
            .overlay {
                if session.preview.playbackFailed {
                    PlaybackFailedNotice(subject: "video")
                } else if session.selected == nil {
                    Text("Tap a moment to watch it")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .overlay(alignment: .topLeading) {
                if let selected = session.selected {
                    Text(Format.duration(selected.seconds))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
    }

    private var summary: String {
        let pending = session.pendingCount
        let added = session.acceptedCount
        let review = pending == 1 ? "1 to review" : "\(pending) to review"
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
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch moment.status {
        case .pending:
            HStack(spacing: 8) {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                Button("Accept", systemImage: "checkmark", action: accept)
                    .buttonStyle(.borderedProminent)
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

    private var caption: String {
        switch moment.sound {
        case .cheering: "Cheering"
        case .applause: "Applause"
        case .shouting: "Shouting"
        case .crowd: "Crowd noise"
        case .loud: "Loud moment"
        }
    }
}
