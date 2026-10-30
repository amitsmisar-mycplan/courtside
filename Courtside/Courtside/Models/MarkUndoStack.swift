import Foundation

/// The marks Undo can remove, newest last, held by identifier — never by position in a list.
///
/// Shared by playback marking and live recording so both behave identically. A burst of taps
/// stays undoable while each action (tap or undo) follows the last within the window (5 s);
/// once the Undo control has been idle that long it hides and the stack is forgotten, so a
/// later Undo can't reach back to a tap from minutes ago.
@MainActor @Observable
final class MarkUndoStack {
    nonisolated static let defaultWindow: Duration = .seconds(5)

    /// Undoable marks, oldest first.
    private(set) var ids: [UUID] = []
    @ObservationIgnored private let window: Duration
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(window: Duration = defaultWindow) {
        self.window = window
    }

    var canUndo: Bool { !ids.isEmpty }

    func push(_ id: UUID) {
        ids.append(id)
        restartWindow()
    }

    /// The most recent undoable mark, removed from the stack. Keeps the control up for the next one.
    func popLatest() -> UUID? {
        guard let id = ids.popLast() else { return nil }
        if ids.isEmpty { clear() } else { restartWindow() }
        return id
    }

    func clear() {
        expiry?.cancel()
        expiry = nil
        ids.removeAll()
    }

    private func restartWindow() {
        expiry?.cancel()
        let window = window
        expiry = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.ids.removeAll()
        }
    }
}
