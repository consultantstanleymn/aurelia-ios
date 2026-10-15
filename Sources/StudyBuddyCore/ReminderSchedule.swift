import Foundation

/// When a reminder next fires.
///
/// Pure and in Core so it can be tested, because "19:30 on weekdays" is arithmetic that goes wrong
/// quietly: an off-by-one in the weekday convention or a boundary at exactly the reminder time
/// produces a reminder that never arrives, or two of them, and neither shows up until a phone has
/// been sat in front of for a week.
///
/// Weekdays here are `Calendar`'s, Sunday = 1 and Saturday = 7 — not 0-based. The reminder schedule
/// stores them that way because it is the same numbering `UNCalendarNotificationTrigger` uses, so
/// the value written into a notification and the value checked here cannot drift apart.
public enum ReminderSchedule {

    /// Parses "HH:mm". Falls back to 19:30 rather than to something arbitrary, because that is what
    /// the Python tutor used for AWS and a malformed entry should not invent a new time.
    public static func time(_ text: String) -> (hour: Int, minute: Int) {
        let hour = Int(text.prefix(2)) ?? 19
        let minute = Int(text.suffix(2)) ?? 30
        return (hour, minute)
    }

    /// The next moment this schedule fires strictly after `now`, or nil if it never does.
    ///
    /// Nine days are searched because a weekly schedule can legitimately have nothing in the next
    /// seven when today is the one weekday it excludes and the time has already passed.
    public static func nextFire(
        time: String,
        weekdays: Set<Int>,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let (hour, minute) = ReminderSchedule.time(time)
        guard !weekdays.isEmpty else { return nil }

        for offset in 0 ... 8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            parts.minute = minute
            guard let candidate = calendar.date(from: parts) else { continue }
            // Strictly after. A reminder whose time is this very minute has either just fired or is
            // about to; either way it is not "next".
            if candidate > now { return candidate }
        }
        return nil
    }

    /// "Tue 19:30", for the settings list.
    public static func describe(
        time: String,
        weekdays: Set<Int>,
        now: Date,
        calendar: Calendar = .current
    ) -> String? {
        guard let fire = nextFire(time: time, weekdays: weekdays, now: now, calendar: calendar) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // The time zone as well, not just the calendar: a DateFormatter keeps its own, and it
        // defaults to the device's. On a machine in a different zone from the calendar passed in,
        // the settings list would show the reminder an hour out from when it actually fires.
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: fire)
    }
}