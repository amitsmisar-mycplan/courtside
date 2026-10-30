import SwiftUI

/// Pick a format, watch it render, done: the clip is in the camera roll.
struct ExportSheet: View {
    let session: ClipExportSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Save to Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if session.isBusy {
                            Button("Cancel") { session.cancel() }
                                .disabled(session.phase == .saving)
                        } else {
                            Button("Close") { dismiss() }
                        }
                    }
                }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(session.isBusy)
        .task { await session.load() }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .choosing:
            VStack(spacing: 12) {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        session.export(format)
                    } label: {
                        HStack(spacing: 14) {
                            FormatIcon(isTall: format == .vertical || (session.sourceSize.map { $0.height > $0.width } ?? false))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.title).font(.headline)
                                Text(format.detail(sourceSize: session.sourceSize)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.down")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        case .exporting:
            VStack(spacing: 14) {
                Text("Making \(session.format == .vertical ? "vertical video" : "video")…").font(.headline)
                ProgressView(value: session.progress)
                Text("\(Int(session.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        case .saving:
            ProgressView("Saving to Photos…")
                .frame(maxHeight: .infinity)
        case .saved:
            ContentUnavailableView {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
            } description: {
                Text("It's in your camera roll, ready to post.")
            } actions: {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .denied:
            ContentUnavailableView {
                Label("Courtside can't save to Photos", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Photos access is turned off for Courtside. Turn on \"Add Photos Only\" in Settings, then try again.")
            } actions: {
                if let url = PhotoLibraryService.settingsURL {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't save the video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let format = session.format {
                    Button("Try Again") { session.export(format) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// A small frame showing the shape each format saves.
private struct FormatIcon: View {
    let isTall: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: isTall ? 20 : 34, height: isTall ? 34 : 20)
            .frame(width: 36, height: 36)
    }
}
