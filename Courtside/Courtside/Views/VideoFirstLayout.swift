import SwiftUI

/// A video above its controls, where the video gets all the height the controls leave. The
/// controls keep their natural size; on a short screen (or at large Dynamic Type) the video
/// shrinks first, down to `minVideoHeight`, and only past that does the page scroll.
struct VideoFirstLayout<Video: View, Controls: View>: View {
    var minVideoHeight: CGFloat = 180
    var spacing: CGFloat = 8
    @ViewBuilder var video: Video
    @ViewBuilder var controls: Controls

    /// Measured after the first layout; until then a typical value keeps the first frame close.
    @State private var controlsHeight: CGFloat = 160

    private let verticalPadding: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: spacing) {
                    video
                        .frame(maxWidth: .infinity)
                        .frame(height: videoHeight(available: geometry.size.height))
                    controls
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                }
                .padding(.horizontal)
                .padding(.vertical, verticalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// `available` is the space between the navigation bar and the bottom safe area.
    private func videoHeight(available: CGFloat) -> CGFloat {
        let free = available - controlsHeight - spacing - verticalPadding * 2
        return max(minVideoHeight, free.rounded(.down))
    }
}
