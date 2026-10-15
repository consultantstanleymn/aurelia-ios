import Foundation

/// The parts of progress tracking that are arithmetic rather than storage.
///
/// Extracted from `ProgressStore` so they can be tested on Linux. The store itself needs
/// `sqlite3.h` and a `-lsqlite3` link, and the machine has the runtime library but not the
/// development symlink, so bringing in `sqlite-devel` would mean a package install — for a handful
/// of decisions that are worth testing far more than the SQL plumbing around them.
///
/// The spaced-repetition ladder and the streak rule are the two places a silent mistake would be
/// invisible: a wrong interval just makes the tutor feel wrong, and a wrong streak makes it lie to
/// the learner about their own progress.
public enum MasteryLadder {

    /// Days until a topic comes back, by level reached. A hit climbs one rung; a miss drops to the
    /// bottom and returns tomorrow.
    ///
    /// The ladder is the Python tutor's. Short at the start because a topic misremembered once
    /// should be seen again quickly, and long at the end because something answered five times in a
    /// row is probably learned.
    public static let intervals: [TimeInterval] = [1, 3, 7, 16, 35]
    public static let maximumLevel = 5

    /// Where a correct answer takes the topic, and when it is next due.
    ///
    /// The interval is indexed by the level the topic was *at*, not the one it lands on. That
    /// distinction is the whole first rung: a topic answered correctly for the first time should
    /// come back tomorrow, not in three days, because nothing has been consolidated yet. Indexing
    /// by the new level silently gave a brand-new topic a three-day gap.
    public static func hit(currentLevel: Int, now: Date = Date()) -> (level: Int, due: Date) {
        let next = min(currentLevel + 1, maximumLevel)
        let rung = min(max(currentLevel, 0), intervals.count - 1)
        return (next, now.addingTimeInterval(60 * 60 * 24 * intervals[rung]))
    }

    /// A miss resets the topic rather than demoting it, so the next session starts from the
    /// shortest interval again.
    public static func miss(now: Date = Date()) -> (level: Int, due: Date) {
        (0, now.addingTimeInterval(60 * 60 * 24))
    }

    public static func isDue(level: Int, nextDue: Date?, now: Date = Date()) -> Bool {
        guard let nextDue else { return true }
        return nextDue <= now
    }
}

public enum StreakCalculator {

    /// Consecutive days with a session, counting back from today.
    ///
    /// A streak is still alive if the learner has not studied *today* but did yesterday — otherwise
    /// every morning the number drops to zero and the tutor congratulates them on nothing. Once two
    /// days pass it is genuinely over and the count starts from whatever is in the past.
    public static func streak(days: Set<Date>, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard !days.isEmpty else { return 0 }
        let ordinals = Set(days.map { calendar.startOfDay(for: $0) })

        var cursor = calendar.startOfDay(for: now)
        if !ordinals.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  ordinals.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while ordinals.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Total minutes from session spans, clamped so an unterminated session cannot report a
    /// negative or absurd duration.
    public static func minutes(spans: [(start: Date, end: Date?)]) -> Int {
        let seconds = spans.reduce(0.0) { total, span in
            guard let end = span.end else { return total }
            return total + max(0, end.timeIntervalSince(span.start))
        }
        return Int(seconds / 60)
    }
}
