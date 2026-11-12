import Foundation
import SwiftData

/// The "Find Moments" screen for one part (decision 0029): runs the scan, previews a suggestion
/// from the part's video, and turns Accept into an ordinary mark. The screen shows state and sends
/// intents.
@MainActor @Observable
final class MomentReviewSession {
    let part: GamePart
    let finder: MomentFinder
    /// Loops the selected moment's clip window, straight from the part's video.
    let preview = LoopingClipPlayer()
    private(set) var selectedID: UUID?

    @ObservationIgnored private let context: ModelContext

    init(part: GamePart, context: ModelContext, finder: MomentFinder? = nil) {
        self.part = part
        self.context = context
        self.finder = finder ?? MomentFinder()
    }

    /// The scan has finished for this part at least once.
    var hasResults: Bool { part.momentsFoundAt != nil }

    var moments: [SuggestedMoment] { part.orderedSuggestions }
    var pendingCount: Int { part.pendingSuggestionCount }
    var acceptedCount: Int { part.suggestions.filter { $0.status == .accepted }.count }

    var selected: SuggestedMoment? {
        moments.first { $0.id == selectedID }
    }

    /// The window a clip would get if this moment were accepted now.
    func window(for moment: SuggestedMoment) -> ClipWindow {
        ClipWindow.around(mark: moment.seconds, preRoll: ClipSettings.preRoll, postRoll: ClipSettings.postRoll,
                          gameDuration: part.durationSeconds)
    }

    // MARK: Intents

    /// Opening the screen: shows earlier results, or starts (or resumes) listening.
    func appear() {
        if hasResults {
            selectFirstPending()
        } else {
            find()
        }
    }

    func find() {
        guard finder.phase != .running else { return }
        finder.start(part: part, context: context)
        Task { [weak self] in
            await self?.finder.waitUntilDone()
            guard let self, self.finder.phase == .finished else { return }
            self.selectFirstPending()
        }
    }

    func stop() {
        finder.cancel()
    }

    /// Back on screen after iOS paused the scan: carry on from where it stopped.
    func resumeIfInterrupted() {
        guard finder.phase == .interrupted else { return }
        find()
    }

    func select(_ moment: SuggestedMoment) {
        guard part.isVideoAvailable else { return }
        selectedID = moment.id
        preview.load(StorageManager.videoURL(for: part), range: window(for: moment))
    }

    func accept(_ moment: SuggestedMoment) {
        moment.accept(in: context)
        advance(from: moment)
    }

    func dismiss(_ moment: SuggestedMoment) {
        moment.dismiss(in: context)
        advance(from: moment)
    }

    func undo(_ moment: SuggestedMoment) {
        moment.undo(in: context)
    }

    /// The screen is closing.
    func close() {
        preview.pause()
        finder.cancel()
    }

    // MARK: Selection

    private func selectFirstPending() {
        guard selectedID == nil, let first = moments.first(where: { $0.status == .pending }) ?? moments.first else { return }
        select(first)
    }

    /// After deciding on the selected moment, the next one still pending.
    private func advance(from moment: SuggestedMoment) {
        guard selectedID == moment.id else { return }
        let list = moments
        let index = list.firstIndex { $0.id == moment.id } ?? 0
        let next = list[(index + 1)...].first { $0.status == .pending } ?? list.first { $0.status == .pending }
        if let next { select(next) }
    }
}
