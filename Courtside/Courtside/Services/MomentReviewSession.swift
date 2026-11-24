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
    /// Decided moments leave the list; this brings them back, with Undo (decision 0031).
    var showsReviewed = false
    /// The last Accept or Dismiss, offered for Undo until the next decision.
    private(set) var lastDecision: SuggestedMoment?
    /// Just decided: still listed, showing Added or Dismissed, until the screen fades them out.
    private(set) var leavingIDs: Set<UUID> = []

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
    var reviewedCount: Int { moments.count - pendingCount }

    /// What the list shows: the moments still to review, or every moment when asked.
    var visibleMoments: [SuggestedMoment] {
        showsReviewed ? moments : moments.filter { $0.status == .pending || leavingIDs.contains($0.id) }
    }

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
            guard let self else { return }
            // A stopped scan again goes back to the list it started from.
            guard self.finder.phase == .finished || (self.finder.phase == .cancelled && self.hasResults) else { return }
            self.selectFirstPending()
        }
    }

    /// "Scan Again" is offered once a scan has finished, and not while one is running or its
    /// failure is on screen (that screen offers Find Moments again instead).
    var canScanAgain: Bool {
        guard hasResults else { return false }
        switch finder.phase {
        case .running, .interrupted, .failed: return false
        case .idle, .finished, .cancelled: return true
        }
    }

    /// Listens to the part again (decision 0029, amended): from the beginning, unless an earlier
    /// scan again was stopped part way, which picks up where it stopped like a first scan. When it
    /// finishes, the suggestions still waiting are replaced; accepted and dismissed ones stay, and
    /// nothing new is suggested near them or near a mark. Stopping it changes nothing.
    func scanAgain() {
        guard canScanAgain else { return }
        selectedID = nil
        preview.pause()
        lastDecision = nil
        leavingIDs = []
        showsReviewed = false
        find()
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
        guard moment.status == .pending else { return }
        moment.accept(in: context)
        decided(moment)
    }

    func dismiss(_ moment: SuggestedMoment) {
        guard moment.status == .pending else { return }
        moment.dismiss(in: context)
        decided(moment)
    }

    /// Puts the moment back in the list as pending, and shows it.
    func undo(_ moment: SuggestedMoment) {
        guard moment.canUndo else { return }
        moment.undo(in: context)
        leavingIDs.remove(moment.id)
        if lastDecision?.id == moment.id { lastDecision = nil }
        // Nothing reviewed left: the switch is hidden, so it mustn't stay on.
        if reviewedCount == 0 { showsReviewed = false }
        select(moment)
    }

    /// Undo for the last decision (the bar at the bottom of the list).
    func undoLast() {
        guard let lastDecision else { return }
        undo(lastDecision)
    }

    /// The screen has shown the decision; the moment leaves the list (unless reviewed ones are shown).
    func finishLeaving(_ moment: SuggestedMoment) {
        leavingIDs.remove(moment.id)
    }

    /// The Undo bar timed out or was dismissed.
    func forgetLastDecision() {
        lastDecision = nil
    }

    /// Full screen's arrows: the next or previous moment in the list, wrapping round.
    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    var canStep: Bool { visibleMoments.count > 1 }

    /// The screen is closing.
    func close() {
        preview.pause()
        finder.cancel()
    }

    // MARK: Selection

    private func selectFirstPending() {
        // With everything reviewed nothing is selected: the list doesn't show those moments.
        guard selectedID == nil, let first = moments.first(where: { $0.status == .pending }) else { return }
        select(first)
    }

    private func decided(_ moment: SuggestedMoment) {
        lastDecision = moment
        leavingIDs.insert(moment.id)
        advance(from: moment)
    }

    /// After deciding on the selected moment, the next one still pending; with none left, the
    /// preview stops.
    private func advance(from moment: SuggestedMoment) {
        guard selectedID == moment.id else { return }
        let list = moments
        let index = list.firstIndex { $0.id == moment.id } ?? 0
        let next = list[(index + 1)...].first { $0.status == .pending } ?? list.first { $0.status == .pending }
        if let next {
            select(next)
        } else {
            selectedID = nil
            preview.pause()
        }
    }

    private func step(by offset: Int) {
        let list = visibleMoments
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : 0)
        let next = (index + offset + list.count) % list.count
        select(list[next])
    }
}
