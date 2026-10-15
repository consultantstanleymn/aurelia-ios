import XCTest
@testable import StudyBuddyCore

/// The progress store, against real SQLite.
///
/// This is the one part of the app that had never been executed by anything. Every method sits
/// behind `#if canImport(SQLite3)`, which is false on Linux because the system headers ship no
/// module map — so under `swift test` the entire class compiled to nothing, and the six queries
/// behind it had only ever run on a phone nobody had tested on. The shim target in
/// `Sources/CSQLiteShim` is what makes these tests possible.
///
/// The numbers the tutor reports back — streak, minutes, days covered, what you keep missing — come
/// straight out of here, and a wrong one is worse than a missing one: the tutor would tell the
/// learner something untrue about their own progress.
final class ProgressStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ProgressStore!

    private let track = "aws"
    private let day: TimeInterval = 60 * 60 * 24
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aurelia-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try ProgressStore(path: directory.appendingPathComponent("progress.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - opening

    func testAStoreOpensAndCreatesItsFile() throws {
        let path = directory.appendingPathComponent("progress.sqlite").path
        let fresh = try ProgressStore(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the database file should exist once opened")
        _ = fresh
    }

    /// Opening the same path twice must not throw the schema away.
    func testOpeningTwiceIsSafe() throws {
        try store.addNote("keep me", track: track, day: 1, now: now)
        let again = try ProgressStore(path: directory.appendingPathComponent("progress.sqlite").path)
        XCTAssertEqual(try again.recentNotes(track: track).count, 1)
    }

    // MARK: - the mastery ladder

    func testAHitClimbsTheLadderAndAMissResetsIt() throws {
        XCTAssertEqual(try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now), 1)
        XCTAssertEqual(try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now), 2)
        XCTAssertEqual(try store.recordAnswer(track: track, topic: "S3", result: .miss, now: now), 0)
        XCTAssertEqual(try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now), 1)
    }

    /// A topic missed more often than hit is the weak list, and it is what the prompt opens with.
    func testWeakTopicsAreTheOnesLostTo() throws {
        try store.recordAnswer(track: track, topic: "VPC peering", result: .miss, now: now)
        try store.recordAnswer(track: track, topic: "VPC peering", result: .miss, now: now)
        try store.recordAnswer(track: track, topic: "IAM policy", result: .hit, now: now)
        try store.recordAnswer(track: track, topic: "Route tables", result: .miss, now: now)
        try store.recordAnswer(track: track, topic: "Route tables", result: .hit, now: now)

        let weak = try store.weakTopics(track: track)
        XCTAssertEqual(weak.map(\.topic), ["VPC peering"], "only a genuine loss belongs on the weak list")
        XCTAssertEqual(weak.first?.misses, 2)
        XCTAssertEqual(weak.first?.hits, 0)
    }

    func testTracksDoNotLeakIntoEachOther() throws {
        try store.recordAnswer(track: "aws", topic: "S3", result: .miss, now: now)
        XCTAssertEqual(try store.weakTopics(track: "lsat").count, 0)
        XCTAssertEqual(try store.weakTopics(track: "aws").count, 1)
    }

    /// A miss comes back tomorrow, a hit climbs the ladder. Due dates are the whole point of the
    /// table, so they are checked against the clock rather than trusted.
    func testDueDatesFollowTheLadder() throws {
        try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now)
        XCTAssertEqual(try store.dueTopics(track: track, now: now).count, 0, "not due straight away")

        XCTAssertEqual(try store.dueTopics(track: track, now: now.addingTimeInterval(day)).count, 1)
        try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now.addingTimeInterval(day))
        XCTAssertEqual(
            try store.dueTopics(track: track, now: now.addingTimeInterval(day)).count,
            0,
            "the second rung pushes it three days out"
        )
        // Measured from when the answer was given, not from the first one: the topic was answered
        // on day one, so the three-day rung lands four days after the start.
        XCTAssertEqual(
            try store.dueTopics(track: track, now: now.addingTimeInterval(4 * day)).count, 1
        )
    }

    /// The due list carries the counts with it, and they were read out of the row backwards: column 1
    /// is the misses and column 2 is the hits, and they were the other way round. A topic missed
    /// once and hit twice came back claiming two misses and one hit.
    func testDueTopicsCountMissesAndHitsTheRightWayRound() throws {
        try store.recordAnswer(track: track, topic: "S3", result: .miss, now: now)
        for _ in 0..<2 { try store.recordAnswer(track: track, topic: "S3", result: .hit, now: now) }

        let due = try store.dueTopics(track: track, now: now.addingTimeInterval(4 * day))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.topic, "S3")
        XCTAssertEqual(due.first?.misses, 1)
        XCTAssertEqual(due.first?.hits, 2)
    }

    /// Nothing has been answered, so nothing is due. Without the answer-count guard a fresh install
    /// would hand the tutor a review list of topics the learner has never been asked about.
    func testNothingIsDueBeforeAnythingIsAnswered() throws {
        XCTAssertEqual(try store.dueTopics(track: track, now: now.addingTimeInterval(400 * day)).count, 0)
    }

    // MARK: - coverage

    func testCoveredSectionsArePerDayAndNotDuplicated() throws {
        try store.markCovered(track: track, day: 3, section: "VPC design", now: now)
        try store.markCovered(track: track, day: 3, section: "VPC design", now: now)
        try store.markCovered(track: track, day: 3, section: "IAM design", now: now)
        try store.markCovered(track: track, day: 4, section: "Cost", now: now)

        XCTAssertEqual(try store.coveredSections(track: track, day: 3), ["IAM design", "VPC design"])
        XCTAssertEqual(try store.coveredSections(track: track, day: 4), ["Cost"])
    }

    // MARK: - days

    func testTheAppOpensOnTheFirstDayNotYetDone() throws {
        XCTAssertEqual(try store.nextDay(track: track, total: 70), 1)
        try store.setDayStatus(.done, track: track, day: 1, now: now)
        try store.setDayStatus(.done, track: track, day: 2, now: now)
        XCTAssertEqual(try store.nextDay(track: track, total: 70), 3)
    }

    /// Finishing the syllabus should leave you on the last day, not throw you back to the first.
    /// This returned 1 for want of a `max` where a `min` was written, so a learner who completed
    /// all 70 days was told "Day 1 of 70" every time they opened the app.
    func testAFinishedTrackOpensOnItsLastDay() throws {
        for day in 1...5 { try store.setDayStatus(.done, track: track, day: day, now: now) }
        XCTAssertEqual(try store.nextDay(track: track, total: 5), 5)
    }

    func testDayStatusRoundTrips() throws {
        XCTAssertNil(try store.dayStatus(track: track, day: 2))
        try store.setDayStatus(.open, track: track, day: 2, now: now)
        XCTAssertEqual(try store.dayStatus(track: track, day: 2), .open)
        try store.setDayStatus(.done, track: track, day: 2, now: now)
        XCTAssertEqual(try store.dayStatus(track: track, day: 2), .done, "the upsert should replace, not duplicate")
        XCTAssertEqual(try store.completedDays(track: track), [2])
    }

    // MARK: - notes and todos

    func testRecentNotesComeBackNewestFirstAndRespectTheLimit() throws {
        try store.addNote("first", track: track, day: 1, now: now)
        try store.addNote("second", track: track, day: 1, now: now.addingTimeInterval(60))
        try store.addNote("third", track: track, day: 2, now: now.addingTimeInterval(120))

        let notes = try store.recentNotes(track: track, limit: 2)
        XCTAssertEqual(notes.map(\.note), ["third", "second"])
        XCTAssertEqual(notes.first?.day, 2, "the note remembers which day it came from")
    }

    /// A note with an apostrophe in it is the sort of thing a learner actually writes, and it goes
    /// through a bound parameter rather than into the SQL text.
    func testNotesSurviveQuotes() throws {
        try store.addNote("It's the route table's job, not the gateway's.", track: track, day: 1, now: now)
        XCTAssertEqual(
            try store.recentNotes(track: track).first?.note,
            "It's the route table's job, not the gateway's."
        )
    }

    func testTodosOpenUntilCompleted() throws {
        let id = try store.addTodo(
            title: "Redraw the VPC diagram",
            detail: "One public subnet, two private",
            track: track, day: 4, now: now
        )
        let open = try store.openTodos(track: track)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.title, "Redraw the VPC diagram")
        XCTAssertEqual(open.first?.body, "One public subnet, two private")

        try store.completeTodo(id: id, now: now)
        XCTAssertEqual(try store.openTodos(track: track).count, 0)
    }

    // MARK: - sessions, streak and minutes

    func testMinutesAddUpFromFinishedSessions() throws {
        let first = try store.startSession(track: track, day: 1, mode: "teach", now: now)
        try store.endSession(id: first, now: now.addingTimeInterval(20 * 60))
        let second = try store.startSession(track: track, day: 1, mode: "teach", now: now.addingTimeInterval(30 * 60))
        try store.endSession(id: second, now: now.addingTimeInterval(50 * 60))

        let stats = try store.stats(track: track, now: now)
        XCTAssertEqual(stats.minutes, 40, "twenty minutes plus another twenty")
        XCTAssertEqual(stats.streak, 1, "both sessions were today, so the streak is one day")
    }

    /// A session left running when the app was killed reports zero minutes rather than a negative
    /// number or a duration measured to the end of time.
    func testAnUnfinishedSessionContributesNothing() throws {
        _ = try store.startSession(track: track, day: 1, mode: "teach", now: now)
        let stats = try store.stats(track: track, now: now.addingTimeInterval(3600))
        XCTAssertEqual(stats.minutes, 0)
        XCTAssertEqual(stats.streak, 1, "the day still counts as studied")
    }

    func testStreakCountsConsecutiveDays() throws {
        for daysAgo in 0...3 {
            let session = try store.startSession(
                track: track, day: 1, mode: "teach",
                now: now.addingTimeInterval(-Double(daysAgo) * day)
            )
            try store.endSession(id: session, now: now.addingTimeInterval(-Double(daysAgo) * day + 600))
        }
        XCTAssertEqual(try store.stats(track: track, now: now).streak, 4)
    }

    /// Yesterday and the day before still count as a streak — otherwise every morning before the first
    /// answer of the day the number would read zero and the tutor would congratulate the learner on
    /// nothing.
    func testAStreakFromYesterdayStillCounts() throws {
        for daysAgo in [1, 2] {
            let session = try store.startSession(
                track: track, day: 1, mode: "teach",
                now: now.addingTimeInterval(-Double(daysAgo) * day)
            )
            try store.endSession(id: session, now: now.addingTimeInterval(-Double(daysAgo) * day + 600))
        }
        XCTAssertEqual(try store.stats(track: track, now: now).streak, 2)
    }

    /// Two days back is the end of it. Past that the run is genuinely broken.
    func testAGapBreaksTheStreak() throws {
        for daysAgo in [4, 5] {
            let session = try store.startSession(
                track: track, day: 1, mode: "teach",
                now: now.addingTimeInterval(-Double(daysAgo) * day)
            )
            try store.endSession(id: session, now: now.addingTimeInterval(-Double(daysAgo) * day + 600))
        }
        XCTAssertEqual(try store.stats(track: track, now: now).streak, 0, "nothing today or yesterday")
    }

    // MARK: - key/value

    func testValuesRoundTrip() throws {
        XCTAssertNil(try store.value(for: "voice.url"))
        try store.setValue("http://127.0.0.1:8000", for: "voice.url")
        XCTAssertEqual(try store.value(for: "voice.url"), "http://127.0.0.1:8000")
        try store.setValue("", for: "voice.url")
        XCTAssertEqual(try store.value(for: "voice.url"), "", "clearing is not the same as absent")
    }

    // MARK: - surviving a relaunch

    /// The whole point of the store: the learner closes the app and comes back tomorrow. Every
    /// kind of record has to still be there, because the app is the only place it exists.
    func testEverythingSurvivesClosingAndReopening() throws {
        try store.recordAnswer(track: track, topic: "S3", result: .miss, now: now)
        try store.markCovered(track: track, day: 1, section: "Storage", now: now)
        try store.setDayStatus(.done, track: track, day: 1, now: now)
        try store.addNote("remember the lifecycle rule", track: track, day: 1, now: now)
        let todo = try store.addTodo(title: "Read the whitepaper", detail: "", track: track, day: 1, now: now)
        let session = try store.startSession(track: track, day: 1, mode: "teach", now: now)
        try store.endSession(id: session, now: now.addingTimeInterval(600))

        store = nil
        let reopened = try ProgressStore(path: directory.appendingPathComponent("progress.sqlite").path)

        XCTAssertEqual(try reopened.weakTopics(track: track).map(\.topic), ["S3"])
        XCTAssertEqual(try reopened.coveredSections(track: track, day: 1), ["Storage"])
        XCTAssertEqual(try reopened.dayStatus(track: track, day: 1), .done)
        XCTAssertEqual(try reopened.nextDay(track: track, total: 70), 2)
        XCTAssertEqual(try reopened.recentNotes(track: track).first?.note, "remember the lifecycle rule")
        XCTAssertEqual(try reopened.openTodos(track: track).count, 1)
        XCTAssertEqual(try reopened.stats(track: track, now: now).minutes, 10)
        _ = todo
    }
}