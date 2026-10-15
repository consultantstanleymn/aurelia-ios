import XCTest
@testable import StudyBuddyCore

/// The progress rules, tested away from SQLite.
///
/// The store needs `sqlite3.h` and `-lsqlite3`, and this machine has the runtime library but not
/// the development symlink — bringing in `sqlite-devel` is a package install for very little. The
/// ladder and the streak are the parts where a silent mistake would be *invisible*: a wrong interval
/// just makes the tutor feel vaguely wrong, and a wrong streak makes it lie about the learner's own
/// progress. Those are worth testing; the SQL plumbing is thin and gets covered on the device.
final class ProgressMathTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 60 * 60 * 24

    func testAHitClimbsOneRungAndPushesTheDateOut() {
        let first = MasteryLadder.hit(currentLevel: 0, now: now)
        XCTAssertEqual(first.level, 1)
        XCTAssertEqual(first.due.timeIntervalSince(now), day, accuracy: 1)

        let second = MasteryLadder.hit(currentLevel: 1, now: now)
        XCTAssertEqual(second.level, 2)
        XCTAssertEqual(second.due.timeIntervalSince(now), 3 * day, accuracy: 1)
    }

    func testTheLadderIsCappedRatherThanRunningAway() {
        let top = MasteryLadder.hit(currentLevel: MasteryLadder.maximumLevel, now: now)
        XCTAssertEqual(top.level, MasteryLadder.maximumLevel)
        XCTAssertEqual(top.due.timeIntervalSince(now), day * 35, accuracy: 1)
    }

    /// A miss resets rather than demoting, so the next session starts at the shortest interval
    /// again instead of drifting down one rung at a time.
    func testAMissResetsTheTopic() {
        let outcome = MasteryLadder.miss(now: now)
        XCTAssertEqual(outcome.level, 0)
        XCTAssertEqual(outcome.due.timeIntervalSince(now), day, accuracy: 1)
    }

    func testIntervalsAreIncreasing() {
        let sorted = MasteryLadder.intervals.sorted()
        XCTAssertEqual(sorted, MasteryLadder.intervals)
        XCTAssertGreaterThan(MasteryLadder.intervals.count, 3)
    }

    func testDueComparison() {
        XCTAssertTrue(MasteryLadder.isDue(level: 1, nextDue: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(MasteryLadder.isDue(level: 1, nextDue: now.addingTimeInterval(60), now: now))
        // Never-seen topics are due: otherwise a fresh install never reviews anything.
        XCTAssertTrue(MasteryLadder.isDue(level: 0, nextDue: nil, now: now))
    }

    // MARK: - streak

    private func days(_ offsets: [Int], from base: Date? = nil) -> Set<Date> {
        let base = base ?? now
        return Set(offsets.map { base.addingTimeInterval(Double($0) * day) })
    }

    func testConsecutiveDaysEndingToday() {
        XCTAssertEqual(StreakCalculator.streak(days: days([0, -1, -2, -3]), now: now), 4)
    }

    /// The morning case. Studied yesterday, not yet today — the streak should survive rather than
    /// reporting zero and congratulating the learner on nothing.
    func testStreakSurvivesNotHavingStudiedYetToday() {
        XCTAssertEqual(StreakCalculator.streak(days: days([-1, -2, -3]), now: now), 3)
    }

    func testStreakEndsAfterTwoMissedDays() {
        XCTAssertEqual(StreakCalculator.streak(days: days([-2, -3, -4]), now: now), 0)
    }

    func testAGapBreaksTheRun() {
        // 0, -1, then a missed day, then an older cluster that must not join on.
        XCTAssertEqual(StreakCalculator.streak(days: days([0, -1, -3, -4, -5]), now: now), 2)
    }

    func testNoSessionsMeansNoStreak() {
        XCTAssertEqual(StreakCalculator.streak(days: [], now: now), 0)
    }

    func testFutureDaysDoNotInflateTheStreak() {
        XCTAssertEqual(StreakCalculator.streak(days: days([1, 2, 3]), now: now), 0)
    }

    // MARK: - minutes

    func testMinutesFromSessionSpans() {
        let spans: [(start: Date, end: Date?)] = [
            (now, now.addingTimeInterval(600)),
            (now, now.addingTimeInterval(1200)),
        ]
        XCTAssertEqual(StreakCalculator.minutes(spans: spans), 30)
    }

    /// A session with no end row must contribute nothing rather than a negative duration.
    func testUnterminatedSessionsContributeNothing() {
        let spans: [(start: Date, end: Date?)] = [
            (now, nil),
            (now, now.addingTimeInterval(60)),
        ]
        XCTAssertEqual(StreakCalculator.minutes(spans: spans), 1)
    }
}

final class BoardParserTests: XCTestCase {

    private func board(_ kind: String, _ body: String, title: String = "T") -> BoardItem {
        BoardItem(title: title, kind: kind, body: body)
    }

    func testPointsStripsBulletsAndLetters() {
        let shape = BoardParser.parse(board("points", "- VPC\nB. Subnet\n* Route table\n4. IGW"))
        XCTAssertEqual(shape, .points(title: "T", items: ["VPC", "Subnet", "Route table", "IGW"]))
    }

    func testPointsKeepsNumbersThatArePartOfTheValue() {
        // "15. Reserved" is a value; "A." is a marker. Only a marker is removed.
        let shape = BoardParser.parse(board("points", "15. Reserved is different"))
        XCTAssertEqual(shape, .points(title: "T", items: ["15. Reserved is different"]))
    }

    func testTableSplitsPipesAndTakesAHeader() {
        let shape = BoardParser.parse(board("table", "Service | Use it when\nS3 | static assets\nEC2 | you need an OS"))
        guard case let .table(_, header, rows) = shape else { return XCTFail("not a table: \(shape)") }
        XCTAssertEqual(header, ["Service", "Use it when"])
        XCTAssertEqual(rows, [["S3", "static assets"], ["EC2", "you need an OS"]])
    }

    func testTableWithNoHeaderKeepsEveryRow() {
        let shape = BoardParser.parse(board("table", "1 | 2 | 3\n4 | 5 | 6"))
        guard case let .table(_, header, rows) = shape else { return XCTFail("not a table: \(shape)") }
        XCTAssertEqual(header, [])
        XCTAssertEqual(rows, [["1", "2", "3"], ["4", "5", "6"]])
    }

    func testTableSkipsSeparatorRows() {
        let shape = BoardParser.parse(board("table", "A | B\n---|---\n1 | 2"))
        guard case let .table(_, _, rows) = shape else { return XCTFail("not a table") }
        XCTAssertEqual(rows.count, 1)
    }

    func testCodeKeepsLinesVerbatim() {
        let shape = BoardParser.parse(board("code", "aws s3 cp a s3://b\naws s3 ls"))
        guard case let .code(_, lines) = shape else { return XCTFail("not code") }
        XCTAssertEqual(lines, ["aws s3 cp a s3://b", "aws s3 ls"])
    }

    func testFormulaReadsColonsAndEquals() {
        let shape = BoardParser.parse(board("formula", "RTO: 60 minutes\nRPO = 15 minutes\nno separator here"))
        guard case let .formula(_, pairs) = shape else { return XCTFail("not formula") }
        XCTAssertEqual(pairs, [
            BoardShape.Pair(key: "RTO", value: "60 minutes"),
            BoardShape.Pair(key: "RPO", value: "15 minutes"),
        ])
    }

    func testDiagramIsPassedThrough() {
        let source = "graph TD\n  A-->B"
        let shape = BoardParser.parse(board("diagram", source))
        guard case let .diagram(_, out) = shape else { return XCTFail("not diagram") }
        XCTAssertEqual(out, source)
    }

    func testListIsAnAliasOfPoints() {
        let shape = BoardParser.parse(board("list", "- one\n- two"))
        XCTAssertEqual(shape, .points(title: "T", items: ["one", "two"]))
    }

    func testUnknownKindFallsBackToPointsRatherThanRenderingNothing() {
        // The model invents kinds. An unrecognised one must still show its text.
        let shape = BoardParser.parse(board("timeline", "- then\n- later"))
        XCTAssertEqual(shape, .points(title: "T", items: ["then", "later"]))
    }

    func testATitleIsSynthesisedFromTheKindWhenTheModelOmitsIt() {
        // The prompt asks for a title but the model forgets; an empty heading looks broken, so the
        // kind name stands in.
        let shape = BoardParser.parse(BoardItem(title: "", kind: "table", body: "A | B"))
        XCTAssertEqual(shape.title, "Table")
    }

    func testEmptyBodyProducesNoItemsRatherThanOneBlank() {
        let shape = BoardParser.parse(board("points", "   \n\n  "))
        XCTAssertEqual(shape, .points(title: "T", items: []))
    }
}
