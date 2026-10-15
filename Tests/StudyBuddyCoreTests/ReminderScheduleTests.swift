import XCTest
@testable import StudyBuddyCore

/// When a reminder next fires.
///
/// The defaults come from the Python tutor — AWS at 19:30 on weekdays — and the whole point is that
/// the phone says the same thing at the same time as the thing it replaces. Nothing about a wrong
/// answer here is visible until a real notification has been missed, which is why this is pinned
/// rather than eyeballed.
final class ReminderScheduleTests: XCTestCase {

    /// Fixed zone and a calendar built to match, so the tests do not depend on the machine's
    /// timezone or on whether the day a test happens to run is a daylight-saving change.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }()

    /// A fixed reference: Wednesday 12 March 2025, 09:00 local.
    private func wednesdayMorning(_ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2025, month: 3, day: 12, hour: hour, minute: minute
        ))!
    }

    private let weekdays: Set<Int> = [2, 3, 4, 5, 6]   // Monday to Friday
    private let aws = "19:30"

    // MARK: - the ordinary case

    func testTodayIfTheTimeHasNotPassed() throws {
        let next = ReminderSchedule.nextFire(
            time: aws, weekdays: weekdays, now: wednesdayMorning(), calendar: calendar
        )
        let fire = try XCTUnwrap(next)
        XCTAssertEqual(calendar.component(.weekday, from: fire), 4, "today is Wednesday")
        XCTAssertEqual(calendar.component(.hour, from: fire), 19)
        XCTAssertEqual(calendar.component(.minute, from: fire), 30)
    }

    func testTomorrowWhenTheTimeHasAlreadyPassed() throws {
        let now = wednesdayMorning(20)
        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(time: aws, weekdays: weekdays, now: now, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.day, from: fire), 13, "Thursday")
        XCTAssertEqual(calendar.component(.hour, from: fire), 19)
    }

    /// The exact minute is the interesting one. Today at 19:30:00 has either just fired or is due
    /// within the second, and treating it as "next" would show the learner a time that is now.
    func testTheExactMinuteIsNotNext() throws {
        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(
                time: aws, weekdays: weekdays, now: wednesdayMorning(19, 30), calendar: calendar
            )
        )
        XCTAssertEqual(calendar.component(.day, from: fire), 13)
    }

    /// A minute before is still today. This is the boundary the exact-minute case leans on.
    func testAMinuteBeforeIsStillToday() throws {
        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(
                time: aws, weekdays: weekdays, now: wednesdayMorning(19, 29), calendar: calendar
            )
        )
        XCTAssertEqual(calendar.component(.day, from: fire), 12)
    }

    // MARK: - the weekend

    /// Friday evening rolls over the weekend, and a weekday-only schedule has nothing to offer on
    /// Saturday or Sunday. Nine days are searched so this resolves rather than returning nothing.
    func testFridayEveningRollsToMonday() throws {
        let friday = calendar.date(from: DateComponents(
            year: 2025, month: 3, day: 14, hour: 20, minute: 0
        ))!
        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(time: aws, weekdays: weekdays, now: friday, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.day, from: fire), 17, "Monday")
    }

    func testSaturdayGoesToMonday() throws {
        let saturday = calendar.date(from: DateComponents(
            year: 2025, month: 3, day: 15, hour: 10, minute: 0
        ))!
        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(time: aws, weekdays: weekdays, now: saturday, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.weekday, from: fire), 2, "Monday")
        XCTAssertEqual(calendar.component(.day, from: fire), 17)
    }

    /// A schedule with no days never fires. Handled rather than crashed on: an empty day set is
    /// reachable from stored preferences that were edited badly or written by an older version.
    func testNoDaysMeansItNeverFires() {
        XCTAssertNil(
            ReminderSchedule.nextFire(
                time: aws, weekdays: [], now: wednesdayMorning(), calendar: calendar
            )
        )
    }

    // MARK: - weekday numbering

    /// The convention is Calendar's, Sunday = 1. If this ever drifts, every reminder silently moves
    /// to the wrong day of the week and nothing anywhere reports an error.
    func testSundayIsOneAndSaturdayIsSeven() throws {
        let sunday = calendar.date(from: DateComponents(year: 2025, month: 3, day: 16))!
        let saturday = calendar.date(from: DateComponents(year: 2025, month: 3, day: 15))!
        XCTAssertEqual(calendar.component(.weekday, from: sunday), 1)
        XCTAssertEqual(calendar.component(.weekday, from: saturday), 7)

        let fire = try XCTUnwrap(
            ReminderSchedule.nextFire(time: aws, weekdays: [1], now: saturday, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.weekday, from: fire), 1, "Sunday-only means tomorrow")
    }

    // MARK: - parsing and describing

    func testTimesAreParsed() {
        XCTAssertEqual(ReminderSchedule.time("19:30").hour, 19)
        XCTAssertEqual(ReminderSchedule.time("19:30").minute, 30)
        XCTAssertEqual(ReminderSchedule.time("07:05").hour, 7)
        XCTAssertEqual(ReminderSchedule.time("07:05").minute, 5)
    }

    /// A malformed time falls back to the Python tutor's AWS time rather than to something invented.
    func testAMalformedTimeFallsBackToNineteenThirty() {
        XCTAssertEqual(ReminderSchedule.time("nonsense").hour, 19)
        XCTAssertEqual(ReminderSchedule.time("nonsense").minute, 30)
        XCTAssertEqual(ReminderSchedule.time("").hour, 19)
    }

    func testDescribingShowsTheDayAndTime() {
        let text = ReminderSchedule.describe(
            time: aws, weekdays: weekdays, now: wednesdayMorning(), calendar: calendar
        )
        XCTAssertEqual(text, "Wed 19:30")
    }

    func testDescribingNothingIsNil() {
        XCTAssertNil(
            ReminderSchedule.describe(
                time: aws, weekdays: [], now: wednesdayMorning(), calendar: calendar
            )
        )
    }
}