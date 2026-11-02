import CoreGraphics
import XCTest
@testable import Courtside

/// Label text, fitting, timing, suggestions and titles (decision 0019). Pure rules, no video.
final class GameLabelTests: XCTestCase {
    /// Nov 1, 2026, midday local time.
    private let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!

    private func lines(_ team: String?, _ opponent: String?, _ tournament: String?, _ date: Date? = nil) -> [String]? {
        GameLabel.make(team: team, opponent: opponent, tournament: tournament, date: date)?.lines
    }

    // MARK: Text

    func testAllFieldsSet() {
        XCTAssertEqual(lines("Eagles", "Lakers", "Fall Classic", date), ["Eagles vs Lakers", "Fall Classic · Nov 1, 2026"])
    }

    func testEachMissingCombination() {
        XCTAssertEqual(lines(nil, "Lakers", "Fall Classic", date), ["vs Lakers", "Fall Classic · Nov 1, 2026"])
        XCTAssertEqual(lines("Eagles", nil, "Fall Classic", date), ["Eagles", "Fall Classic · Nov 1, 2026"])
        XCTAssertEqual(lines("Eagles", "Lakers", nil, date), ["Eagles vs Lakers", "Nov 1, 2026"])
        XCTAssertEqual(lines(nil, nil, "Fall Classic", date), ["Fall Classic · Nov 1, 2026"], "line 1 dropped")
        XCTAssertEqual(lines("Eagles", "Lakers", nil, nil), ["Eagles vs Lakers"], "line 2 dropped")
        XCTAssertEqual(lines(nil, "Lakers", nil, nil), ["vs Lakers"])
        XCTAssertEqual(lines(nil, nil, "Fall Classic", nil), ["Fall Classic"])
    }

    func testNoLabelWithoutTeamOpponentOrTournament() {
        XCTAssertNil(lines(nil, nil, nil, date), "the date alone isn't a label")
        XCTAssertNil(lines("  ", "\n", "", date), "blank fields count as empty")
        XCTAssertNil(lines(nil, nil, nil, nil))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(lines("  Eagles ", " Lakers", nil, nil), ["Eagles vs Lakers"])
    }

    func testDateFormatting() {
        XCTAssertEqual(GameLabel.formatted(date), "Nov 1, 2026")
        let december = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 9))!
        XCTAssertEqual(GameLabel.formatted(december), "Dec 25, 2026")
        let may = Calendar.current.date(from: DateComponents(year: 2027, month: 5, day: 9, hour: 23, minute: 59))!
        XCTAssertEqual(GameLabel.formatted(may), "May 9, 2027")
    }

    func testScoreAndNotesAreNeverInTheLabel() {
        let game = Game(label: "Semi-final", recordedAt: date, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
        game.opponent = "Lakers"
        game.ourScore = 54
        game.theirScore = 48
        game.notes = "Sam scored 20"
        let text = GameLabel.forExport(game: game, mode: .openAndClose)?.lines.joined(separator: "\n") ?? ""
        XCTAssertEqual(text, "vs Lakers\nNov 1, 2026")
        for hidden in ["54", "48", "Sam", "Semi-final"] {
            XCTAssertFalse(text.contains(hidden), hidden)
        }
    }

    func testSettingOffOrEmptyGameGivesNoLabel() {
        let game = Game(label: "", recordedAt: date, videoFilename: "x.mov", durationSeconds: 60, source: .imported, videoFileSize: 1)
        XCTAssertNil(GameLabel.forExport(game: game, mode: .openAndClose), "empty game: no label")
        game.team = "Eagles"
        XCTAssertNotNil(GameLabel.forExport(game: game, mode: .openAndClose))
        XCTAssertNil(GameLabel.forExport(game: game, mode: .off), "setting Off")
        XCTAssertNil(GameLabel.forExport(game: nil, mode: .openAndClose))
    }

    // MARK: Fitting

    /// 10 points per character stands in for real text measurement.
    private let measure: (String, Int) -> CGFloat = { text, _ in CGFloat(text.count) * 10 }

    func testShortNamesAreUnchanged() {
        let label = GameLabel.fitted(team: "Eagles", opponent: "Lakers", tournament: "Fall Classic", date: date, maxWidth: 400, measure: measure)
        XCTAssertEqual(label?.lines, ["Eagles vs Lakers", "Fall Classic · Nov 1, 2026"])
    }

    func testLongNamesAreShortenedWithEllipsisToFit() throws {
        let label = try XCTUnwrap(GameLabel.fitted(
            team: "Southern California Elite Basketball Academy 14U Black",
            opponent: "Lakers",
            tournament: "Thanksgiving Weekend Invitational Showcase at the Pyramid",
            date: date,
            maxWidth: 300,
            measure: measure
        ))
        XCTAssertEqual(label.lines.count, 2)
        for line in label.lines {
            XCTAssertLessThanOrEqual(CGFloat(line.count) * 10, 300, line)
        }
        XCTAssertTrue(label.lines[0].hasSuffix(" vs Lakers"), "the short name is kept whole: \(label.lines[0])")
        XCTAssertTrue(label.lines[0].contains("…"))
        XCTAssertTrue(label.lines[1].hasSuffix("… · Nov 1, 2026"), "the date is never cut: \(label.lines[1])")
    }

    func testTwoLongNamesBothShrink() throws {
        let label = try XCTUnwrap(GameLabel.fitted(
            team: String(repeating: "A", count: 40), opponent: String(repeating: "B", count: 40),
            tournament: nil, date: nil, maxWidth: 300, measure: measure
        ))
        let parts = label.lines[0].components(separatedBy: " vs ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.hasSuffix("…") })
        XCTAssertLessThanOrEqual(abs(parts[0].count - parts[1].count), 1, "shortened evenly")
    }

    func testPlacementKeepsTheBoxWithinSeventyPercent() {
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160), CGSize(width: 1080, height: 1920)] {
            let placement = LabelPlacement(canvas: canvas)
            XCTAssertEqual(placement.maxBoxWidth, canvas.width * 0.7, accuracy: 0.5)
            XCTAssertLessThanOrEqual(placement.origin.x + placement.maxBoxWidth, canvas.width * 0.8, "clear of the right edge")
        }
        let tall = LabelPlacement(canvas: CGSize(width: 1080, height: 1920))
        XCTAssertGreaterThanOrEqual(tall.origin.y, 1920 * 0.2, "above Instagram/TikTok's caption band")
        let wide = LabelPlacement(canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(wide.origin, CGPoint(x: 96, y: 54), "inside the 5 % margin, lower left")
    }

    func testRenderedLabelFitsSeventyPercentWithVeryLongNames() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let text = LabelStep.LabelText(
            team: String(repeating: "Southern California Elite ", count: 4), opponent: "Lakers",
            tournament: String(repeating: "Invitational ", count: 10), date: date
        )
        let image = try XCTUnwrap(LabelRenderer.image(for: text, canvas: canvas))
        XCTAssertLessThanOrEqual(image.extent.width, canvas.width * 0.7 + 1)
        XCTAssertEqual(image.extent.minX, 96, accuracy: 0.5)
        XCTAssertNil(LabelRenderer.image(for: LabelStep.LabelText(date: date), canvas: canvas), "never an empty label")
    }

    // MARK: Timing

    func testThirteenSecondClipOpensAndCloses() {
        XCTAssertEqual(LabelTiming.windows(duration: 13), [OverlayWindow(start: 0, end: 2.5), OverlayWindow(start: 10.5, end: 13)])
    }

    func testSevenSecondsIsTheShortestWithBoth() {
        let windows = LabelTiming.windows(duration: 7)
        XCTAssertEqual(windows.count, 2)
        XCTAssertGreaterThanOrEqual(windows[1].start - windows[0].end, 2, "never overlap or merge")
    }

    func testShortClipOpensOnlyForAThird() {
        let short = LabelTiming.windows(duration: 6.9)
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0].start, 0)
        XCTAssertEqual(short[0].end, 2.3, accuracy: 1e-9)
        XCTAssertEqual(LabelTiming.windows(duration: 3), [OverlayWindow(start: 0, end: 1)])
        XCTAssertEqual(LabelTiming.windows(duration: 0), [])
    }

    func testWindowsNeverOverlapAtAnyLength() {
        for tenths in 1...600 {
            let windows = LabelTiming.windows(duration: Double(tenths) / 10)
            if windows.count == 2 { XCTAssertGreaterThan(windows[1].start, windows[0].end) }
            XCTAssertTrue(windows.allSatisfy { $0.end <= Double(tenths) / 10 + 1e-9 })
        }
    }

    func testFadesInAndOutOverPointThreeSeconds() {
        let windows = LabelTiming.windows(duration: 13)
        XCTAssertEqual(LabelTiming.opacity(at: 0, windows: windows), 0)
        XCTAssertEqual(LabelTiming.opacity(at: 0.15, windows: windows), 0.5, accuracy: 0.001)
        XCTAssertEqual(LabelTiming.opacity(at: 1, windows: windows), 1)
        XCTAssertEqual(LabelTiming.opacity(at: 2.35, windows: windows), 0.5, accuracy: 0.001)
        XCTAssertEqual(LabelTiming.opacity(at: 6, windows: windows), 0, "never in the middle")
        XCTAssertEqual(LabelTiming.opacity(at: 12, windows: windows), 1)
        XCTAssertEqual(LabelTiming.opacity(at: 13, windows: windows), 0)
    }

    // MARK: Suggestions and titles

    private func game(_ tournament: String?, daysAgo: Double, team: String? = nil, opponent: String? = nil) -> Game {
        let game = Game(label: "", recordedAt: date.addingTimeInterval(-daysAgo * 86_400), videoFilename: "x.mov",
                        durationSeconds: 60, source: .imported, videoFileSize: 1)
        game.tournament = tournament
        game.team = team
        game.opponent = opponent
        return game
    }

    func testTournamentSuggestionsMostRecentFirstAndUnique() {
        let current = game(nil, daysAgo: 0)
        let games = [
            game("Spring League", daysAgo: 200),
            game("Fall Classic", daysAgo: 10),
            game("fall classic", daysAgo: 30),
            game("Holiday Hoops", daysAgo: 2),
            game(nil, daysAgo: 1),
            current,
        ]
        XCTAssertEqual(GameLabel.tournamentSuggestions(matching: "", in: games, excluding: current),
                       ["Holiday Hoops", "Fall Classic", "Spring League"])
        XCTAssertEqual(GameLabel.tournamentSuggestions(matching: "fa", in: games), ["Fall Classic"])
        XCTAssertEqual(GameLabel.tournamentSuggestions(matching: "Hoops", in: games), ["Holiday Hoops"])
        XCTAssertEqual(GameLabel.tournamentSuggestions(matching: "Fall Classic", in: games), [], "already typed")
    }

    func testTitleAndSubtitle() {
        let entry = game(nil, daysAgo: 0)
        entry.label = "Saturday"
        XCTAssertEqual(entry.displayTitle, "Saturday")
        entry.team = "Eagles"
        XCTAssertEqual(entry.displayTitle, "Saturday", "team alone keeps today's fallbacks")
        entry.opponent = "Lakers"
        XCTAssertEqual(entry.displayTitle, "Eagles vs Lakers")
        entry.team = " "
        XCTAssertEqual(entry.displayTitle, "vs Lakers")
        entry.opponent = nil
        entry.label = ""
        XCTAssertEqual(entry.displayTitle, "Untitled game")

        let dateText = date.formatted(date: .abbreviated, time: .shortened)
        XCTAssertEqual(entry.listSubtitle, dateText)
        entry.tournament = "Fall Classic"
        XCTAssertEqual(entry.listSubtitle, "Fall Classic · \(dateText)")
    }
}
