import SwiftUI

/// Shown while Share makes the labelled copy: progress and Cancel, then the share sheet opens on top.
struct ShareProgressSheet: View {
    let session: ClipShareSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Share")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if session.phase == .preparing {
                            Button("Cancel") { session.cancel() }
                        } else if !session.isBusy {
                            Button("Close") { dismiss() }
                        }
                    }
                }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(session.isBusy)
        .task { session.start() }
        .onDisappear { session.cancel() }
        .onChange(of: session.phase) { _, phase in
            if phase == .finished || phase == .cancelled { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .preparing:
            VStack(spacing: 14) {
                Text("Making video with label…").font(.headline)
                ProgressView(value: session.progress)
                Text("\(Int(session.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Text("Adding label, takes longer").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        case .sharing, .finished, .cancelled:
            ProgressView("Ready to share")
                .frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't make the video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}
