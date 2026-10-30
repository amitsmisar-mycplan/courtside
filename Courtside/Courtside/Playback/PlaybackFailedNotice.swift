import SwiftUI

/// Shown over a player whose video failed to load, instead of a black screen that looks paused.
/// The file itself is left alone: a failed load is not a reason to delete footage.
struct PlaybackFailedNotice: View {
    let subject: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
            Text("This \(subject) can't be played right now")
                .font(.headline)
            Text("Nothing has been deleted. Close Courtside completely and open it again.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }
}
