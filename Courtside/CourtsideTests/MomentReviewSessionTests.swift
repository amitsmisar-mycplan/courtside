import SwiftData
import XCTest
@testable import Courtside

/// The Find Moments review list (decision 0031): decided moments fade out of the list, Undo brings
/// them back, and full screen steps through what's listed.
@MainActor
final class MomentReviewSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Game.self, GamePart.self, Mark.self, Clip.self, SuggestedMoment.self, Player.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    /// A finished scan with suggestions at these seconds, all pending. Nothing on disk: the preview
    /// just fails to load, which these tests don't look at.
    private func makeSession(moments seconds: [Double] = [60, 120, 180]) throws -> MomentReviewSession {
        let game = Game(label: "", recordedAt: .now, videoFilename: "review-test.mov", durationSeconds: 600,
                        source: .imported, videoFileSize: 1)
        context.insert(game)
        let part = GamePart(index: 0, videoFilename: "review-test.mov", durationSeconds: 600, videoFileSize: 1, recordedAt: .now)
        context.insert(part)
        part.game = game
        for second in seconds {
            let moment = SuggestedMoment(seconds: second, score: 4, sound: .cheering)
            context.insert(moment)
            moment.part = part
        }
        part.momentsFoundAt = .now
        try context.save()
        let session = MomentReviewSession(part: part, context: context)
        session.appear()
        return session
    }

    private func times(_ moments: [SuggestedMoment]) -> [Double] { moments.map(\.seconds) }

    func testOpeningSelectsTheFirstPendingMoment() throws {
        let session = try makeSession()
        XCTAssertEqual(session.selected?.seconds, 60)
        XCTAssertEqual(times(session.visibleMoments), [60, 120, 180])
        XCTAssertNil(session.lastDecision)
    }

    func testDecidedMomentsStayUntilTheyFadeThenLeaveTheList() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.selected)

        session.accept(first)
        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(times(session.visibleMoments), [60, 120, 180], "still listed, showing Added")
        XCTAssertEqual(session.selected?.seconds, 120, "moves on to the next pending one")
        XCTAssertEqual(session.lastDecision?.id, first.id, "offered for Undo")

        session.finishLeaving(first)
        XCTAssertEqual(times(session.visibleMoments), [120, 180])
        XCTAssertEqual(session.pendingCount, 2)
        XCTAssertEqual(session.reviewedCount, 1)

        let second = try XCTUnwrap(session.selected)
        session.dismiss(second)
        session.finishLeaving(second)
        XCTAssertEqual(times(session.visibleMoments), [180])
        XCTAssertEqual(session.lastDecision?.id, second.id, "the Undo bar shows the latest decision")

        // Show Reviewed brings decided moments back, in time order.
        session.showsReviewed = true
        XCTAssertEqual(times(session.visibleMoments), [60, 120, 180])
    }

    func testDecidingTheLastOneStopsThePreview() throws {
        let session = try makeSession(moments: [60, 120])
        session.accept(try XCTUnwrap(session.selected))
        session.dismiss(try XCTUnwrap(session.selected))
        XCTAssertNil(session.selected, "nothing left: the preview says All reviewed")
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertEqual(session.acceptedCount, 1)
    }

    func testReopeningWithEverythingReviewedSelectsNothing() throws {
        let session = try makeSession(moments: [60, 120])
        session.accept(try XCTUnwrap(session.selected))
        session.accept(try XCTUnwrap(session.selected))

        let reopened = MomentReviewSession(part: session.part, context: context)
        reopened.appear()
        XCTAssertNil(reopened.selected, "the list doesn't show reviewed moments, so neither does the preview")
        XCTAssertTrue(reopened.visibleMoments.isEmpty)
    }

    func testUndoPutsTheMomentBackSelectsItAndRemovesItsMark() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.selected)
        session.accept(first)
        session.finishLeaving(first)
        XCTAssertEqual(session.part.game?.marks.count, 1)

        session.undoLast()
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(session.part.game?.marks.count, 0, "the mark Accept made is gone")
        XCTAssertEqual(session.selected?.id, first.id, "shown again")
        XCTAssertNil(session.lastDecision)
        XCTAssertEqual(times(session.visibleMoments), [60, 120, 180])
    }

    func testUndoingTheLastReviewedOneTurnsShowReviewedOff() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.selected)
        session.dismiss(first)
        session.finishLeaving(first)
        session.showsReviewed = true

        session.undo(first)
        XCTAssertEqual(session.reviewedCount, 0)
        XCTAssertFalse(session.showsReviewed, "its switch is hidden now, so it mustn't stay on")

        // The next decision fades out again rather than staying listed.
        let next = try XCTUnwrap(session.selected)
        session.dismiss(next)
        session.finishLeaving(next)
        XCTAssertFalse(session.visibleMoments.contains { $0.id == next.id })
    }

    func testDecidingTwiceDoesNothingTheSecondTime() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.selected)
        session.accept(first)
        session.dismiss(first)
        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(session.part.game?.marks.count, 1)
    }

    func testFullScreenArrowsStepThroughTheListAndWrap() throws {
        let session = try makeSession()
        XCTAssertTrue(session.canStep)
        session.selectNext()
        XCTAssertEqual(session.selected?.seconds, 120)
        session.selectNext()
        session.selectNext()
        XCTAssertEqual(session.selected?.seconds, 60, "wraps round")
        session.selectPrevious()
        XCTAssertEqual(session.selected?.seconds, 180)

        // Reviewed moments are skipped, as they're not listed.
        let last = try XCTUnwrap(session.selected)
        session.dismiss(last)
        session.finishLeaving(last)
        session.selectNext()
        session.selectNext()
        XCTAssertNotEqual(session.selected?.seconds, 180)

        let single = try makeSession(moments: [90])
        XCTAssertFalse(single.canStep, "no arrows for a single moment")
    }
}
