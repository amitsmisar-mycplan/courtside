import SwiftUI

/// Full-screen, looping preview of the slow-mo composition. Plays the session's own player —
/// no second player or composition. Turns the screen to match the video (decision 0012).
struct SlowMoPreviewPlayer: View {
    let session: SlowMoSession

    @Environment(\.dismiss) private var dismiss
    @State private var indicatorOpacity = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(player: session.player)
                .ignoresSafeArea()

            // The whole screen pauses and resumes.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { togglePause() }

            if session.isBuildingPreview {
                ProgressView().tint(.white).controlSize(.large)
            }

            Image(systemName: session.isPreviewPaused ? "pause.fill" : "play.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .padding(28)
                .background(.black.opacity(0.5), in: Circle())
                .opacity(session.isPreviewPaused ? 1 : indicatorOpacity)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.6), in: Circle())
                    }
                    .accessibilityLabel("Close preview")
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .lockedOrientation(session.isPortrait ? .portrait : .landscape)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.preview()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.closePreview()
        }
        .onChange(of: session.errorMessage) { _, message in
            // The sheet underneath shows the error; it can't while this covers it.
            if message != nil { dismiss() }
        }
    }

    private func togglePause() {
        session.togglePreviewPause()
        // A brief play symbol on resume so the tap visibly did something; pause stays shown.
        guard !session.isPreviewPaused else { return }
        indicatorOpacity = 1
        withAnimation(.easeOut(duration: 0.6).delay(0.3)) { indicatorOpacity = 0 }
    }
}
