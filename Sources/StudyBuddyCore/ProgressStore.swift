import Foundation
// Two spellings of the same module: the Darwin SDK provides SQLite3, and CSQLiteShim re-exports the
// system header for Linux, which has no module map of its own. Before the shim existed this
// checked false on Linux and the whole store below compiled to nothing under `swift test`.
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLiteShim)
import CSQLiteShim
#endif

#if canImport(SQLite3) || canImport(CSQLiteShim)

/// `SQLITE_TRANSIENT` tells SQLite to copy bound text rather than keep the pointer, which matters
/// because a Swift String is not guaranteed to outlive the bind call.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// Everything the tutor remembers between sessions, on the device.
///
/// A direct port of the Python tutor's schema in `db.py`, table for table, because the prompt's
/// mastery and coverage blocks are built from these queries and the spaced-repetition arithmetic is
/// tuned against them. Changing the schema would change what the tutor says.
///
/// SQLite directly rather than CoreData or an ORM: the queries are six statements, the data is
/// small, and writing them out is shorter than configuring anything. `libsqlite3.tbd` is in the
/// Darwin SDK, and this module stays Foundation-only so the tests still run on Linux.
public final class ProgressStore: @unchecked Sendable {

    public enum Status: String, Sendable { case open, done }
    public enum Result: String, Sendable { case hit, miss }

    private var handle: OpaquePointer?
    private let lock = NSLock()

    /// Where the database lives, kept so the app can show it and a test can delete it.
    ///
    /// Declared before `init` and assigned first: the schema migration runs inside `init` and
    /// touches `self`, and Swift will not let that happen before every stored property has a value.
    public let path: String

    /// Everything a failure should say, rather than a bare errno.
    public enum StoreError: LocalizedError {
        case unavailable(String)
        case open(String)
        case statement(String, String)
        case step(String)

        public var errorDescription: String? {
            switch self {
            case let .unavailable(detail): return "SQLite is not available in this build: \(detail)"
            case let .open(detail): return "Could not open the progress database: \(detail)"
            case let .statement(sql, detail): return "SQL failed (\(sql)): \(detail)"
            case let .step(detail): return "SQL step failed: \(detail)"
            }
        }
    }

    public init(path: String) throws {
        self.path = path
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            throw StoreError.open(detail)
        }
        handle = database
        // WAL so a read never blocks the write that is recording the answer he just gave.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
        #endif
        #if !(canImport(SQLite3) || canImport(CSQLiteShim))
        // The module still compiles here so the core suite can run on Linux; only the store itself
        // is unavailable, and it says so rather than silently losing everything.
        throw StoreError.unavailable("SQLite3 is not importable on this platform")
        #endif
    }

    deinit {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        if let handle { sqlite3_close(handle) }
        #endif
    }

    // MARK: - schema

/// The schema, table for table from the Python tutor's `db.py`.
    ///
    /// A static constant rather than a string inside `migrate`, because it is run with
    /// `sqlite3_exec` and nothing else: `sqlite3_prepare_v2` compiles only the **first** statement
    /// in a string and quietly leaves the rest, so passing all seven CREATE TABLEs to it built one
    /// table and dropped the other six. Every query afterwards then failed with "no such table",
    /// which is what the store did on every platform.
    private static let schema = """

        CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS day_progress (
          track TEXT, day INTEGER, status TEXT, updated REAL, PRIMARY KEY (track, day));
        CREATE TABLE IF NOT EXISTS weak (
          track TEXT, topic TEXT, misses INTEGER DEFAULT 0, hits INTEGER DEFAULT 0, last_seen REAL,
          PRIMARY KEY (track, topic));
        CREATE TABLE IF NOT EXISTS notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT, track TEXT, day INTEGER, note TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS coverage (
          track TEXT, day INTEGER, section TEXT, created REAL, PRIMARY KEY (track, day, section));
        CREATE TABLE IF NOT EXISTS todos (
          id INTEGER PRIMARY KEY AUTOINCREMENT, track TEXT, day INTEGER, title TEXT, detail TEXT,
          done INTEGER DEFAULT 0, created REAL, done_at REAL);
        CREATE TABLE IF NOT EXISTS mastery (
          track TEXT, topic TEXT, level INTEGER DEFAULT 0, next_due REAL, hits INTEGER DEFAULT 0,
          misses INTEGER DEFAULT 0, last_result TEXT, updated REAL, PRIMARY KEY (track, topic));
        CREATE TABLE IF NOT EXISTS sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, track TEXT, day INTEGER, mode TEXT,
          started REAL, ended REAL);

    """

    private func migrate() throws {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        guard let handle else { throw StoreError.open("closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, Self.schema, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(message)
            throw StoreError.statement("schema", detail)
        }
        sqlite3_free(message)
        #endif
    }

    // MARK: - mastery

    /// Records one graded answer and moves the topic's next-due date.
    ///
    /// The interval ladder is the Python's: a hit advances one rung, a miss drops to zero and
    /// comes back tomorrow. With `level` and `next_due` in the same row, a hit and a miss on the
    /// same topic cannot interleave — the write is inside the lock and the upsert is atomic.
    @discardableResult
    public func recordAnswer(
        track: String,
        topic: String,
        result: Result,
        now: Date = Date()
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let level = try scalarInt(
            "SELECT level FROM mastery WHERE track = ? AND topic = ?",
            track, topic
        ) ?? 0
        let outcome = result == .hit
            ? MasteryLadder.hit(currentLevel: level, now: now)
            : MasteryLadder.miss(now: now)
        let newLevel = outcome.level
        let nextDue = outcome.due.timeIntervalSince1970

        try run(
            """
            INSERT INTO mastery (track, topic, level, next_due, hits, misses, last_result, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track, topic) DO UPDATE SET
              level = excluded.level, next_due = excluded.next_due,
              hits = mastery.hits + excluded.hits, misses = mastery.misses + excluded.misses,
              last_result = excluded.last_result, updated = excluded.updated
            """,
            track, topic, newLevel, nextDue,
            result == .hit ? 1 : 0, result == .miss ? 1 : 0,
            result.rawValue, now.timeIntervalSince1970
        )

        // `weak` is what the prompt's "MISTAKES CARRIED FORWARD" block reads: missed more than hit.
        try run(
            """
            INSERT INTO weak (track, topic, misses, hits, last_seen) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(track, topic) DO UPDATE SET
              misses = weak.misses + excluded.misses, hits = weak.hits + excluded.hits,
              last_seen = excluded.last_seen
            """,
            track, topic, result == .miss ? 1 : 0, result == .hit ? 1 : 0, now.timeIntervalSince1970
        )
        return newLevel
    }

    /// Topics missed more often than hit, most-missed first. This is the weak list.
    public func weakTopics(track: String) throws -> [WeakTopic] {
        lock.lock()
        defer { lock.unlock() }
        return try query(
            "SELECT topic, misses, hits FROM weak WHERE track = ? AND misses > hits ORDER BY misses - hits DESC, topic",
            track
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return WeakTopic(
                topic: text(statement, 0),
                misses: Int(sqlite3_column_int(statement, 1)),
                hits: Int(sqlite3_column_int(statement, 2))
            )
            #else
            return WeakTopic(topic: "", misses: 0, hits: 0)
            #endif
        }
    }

    /// Topics due for review, soonest first.
    public func dueTopics(track: String, now: Date = Date()) throws -> [WeakTopic] {
        lock.lock()
        defer { lock.unlock() }
        return try query(
            "SELECT topic, misses, hits FROM mastery WHERE track = ? AND next_due <= ? AND hits + misses > 0 ORDER BY next_due",
            track, now.timeIntervalSince1970
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            // Column order is topic, misses, hits — so column 1 is the misses and column 2 is the
            // hits. Reading them the other way round reported every topic backwards, telling the
            // learner they had got something right as many times as they had missed it.
            return WeakTopic(
                topic: text(statement, 0),
                misses: Int(sqlite3_column_int(statement, 1)),
                hits: Int(sqlite3_column_int(statement, 2))
            )
            #else
            return WeakTopic(topic: "", misses: 0, hits: 0)
            #endif
        }
    }

    // MARK: - coverage and days

    public func markCovered(track: String, day: Int, section: String, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "INSERT OR IGNORE INTO coverage (track, day, section, created) VALUES (?, ?, ?, ?)",
            track, day, section, now.timeIntervalSince1970
        )
    }

    public func coveredSections(track: String, day: Int) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return try query("SELECT section FROM coverage WHERE track = ? AND day = ? ORDER BY section", track, day) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return text(statement, 0)
            #else
            return ""
            #endif
        }
    }

    public func setDayStatus(_ status: Status, track: String, day: Int, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try run(
            """
            INSERT INTO day_progress (track, day, status, updated) VALUES (?, ?, ?, ?)
            ON CONFLICT(track, day) DO UPDATE SET status = excluded.status, updated = excluded.updated
            """,
            track, day, status.rawValue, now.timeIntervalSince1970
        )
    }

    public func dayStatus(track: String, day: Int) throws -> Status? {
        lock.lock()
        defer { lock.unlock() }
        let raw = try query("SELECT status FROM day_progress WHERE track = ? AND day = ?", track, day) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return text(statement, 0)
            #else
            return ""
            #endif
        }
        return raw.first.flatMap { Status(rawValue: $0) }
    }

    public func completedDays(track: String) throws -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        let days: [Int] = try query(
            "SELECT day FROM day_progress WHERE track = ? AND status = ?", track, Status.done.rawValue
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return Int(sqlite3_column_int(statement, 0))
            #else
            return 0
            #endif
        }
        return Set(days)
    }

    /// The first day not yet done. Where the app opens.
    ///
    /// Falls back to the **last** day when every day is done, not the first: finishing the syllabus
    /// should leave you on day 70 looking back at it, and this used to return 1 — a `min` where a
    /// `max` was meant — so a learner who had completed all 70 days was told "Day 1 of 70" every
    /// time they opened the app.
    public func nextDay(track: String, total: Int) throws -> Int {
        // Guarded because `1 ... total` traps outright when total is zero, and a malformed
        // curriculum should not be able to take the app down on launch.
        let last = max(total, 1)
        let done = try completedDays(track: track)
        for candidate in 1 ... last where !done.contains(candidate) { return candidate }
        return last
    }

    // MARK: - notes and todos

    @discardableResult
    public func addNote(_ note: String, track: String, day: Int, now: Date = Date()) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "INSERT INTO notes (track, day, note, created) VALUES (?, ?, ?, ?)",
            track, day, note, now.timeIntervalSince1970
        )
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        return handle.map { sqlite3_last_insert_rowid($0) } ?? 0
        #else
        return 0
        #endif
    }

    public func recentNotes(track: String, limit: Int = 5) throws -> [SessionNote] {
        lock.lock()
        defer { lock.unlock() }
        return try query(
            "SELECT day, note FROM notes WHERE track = ? ORDER BY created DESC, id DESC LIMIT ?",
            track, Int64(limit)
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return SessionNote(day: Int(sqlite3_column_int(statement, 0)), note: text(statement, 1))
            #else
            return SessionNote(day: 0, note: "")
            #endif
        }
    }

    @discardableResult
    public func addTodo(
        title: String,
        detail: String,
        track: String,
        day: Int,
        now: Date = Date()
    ) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "INSERT INTO todos (track, day, title, detail, done, created) VALUES (?, ?, ?, ?, 0, ?)",
            track, day, title, detail, now.timeIntervalSince1970
        )
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        return handle.map { sqlite3_last_insert_rowid($0) } ?? 0
        #else
        return 0
        #endif
    }

    public func openTodos(track: String) throws -> [Todo] {
        lock.lock()
        defer { lock.unlock() }
        return try query(
            "SELECT title, detail FROM todos WHERE track = ? AND done = 0 ORDER BY created", track
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return Todo(title: text(statement, 0), body: text(statement, 1), done: false)
            #else
            return Todo(title: "", body: "", done: false)
            #endif
        }
    }

    public func completeTodo(id: Int64, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "UPDATE todos SET done = 1, done_at = ? WHERE id = ?", now.timeIntervalSince1970, id
        )
    }

    // MARK: - sessions and stats

    public func startSession(track: String, day: Int, mode: String, now: Date = Date()) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "INSERT INTO sessions (track, day, mode, started) VALUES (?, ?, ?, ?)",
            track, day, mode, now.timeIntervalSince1970
        )
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        return handle.map { sqlite3_last_insert_rowid($0) } ?? 0
        #else
        return 0
        #endif
    }

    public func endSession(id: Int64, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("UPDATE sessions SET ended = ? WHERE id = ?", now.timeIntervalSince1970, id)
    }

    /// Streak in days and total minutes, which the prompt reports back to the learner.
    public func stats(track: String, now: Date = Date()) throws -> (streak: Int, minutes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let spans: [SessionSpan] = try query(
            """
            SELECT started, COALESCE(ended, started) FROM sessions
            WHERE track = ? AND started > ? ORDER BY started DESC
            """,
            track, now.addingTimeInterval(-60 * 60 * 24 * 120).timeIntervalSince1970
        ) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return SessionSpan(start: text(statement, 0), end: text(statement, 1))
            #else
            return SessionSpan(start: "", end: "")
            #endif
        }

        var dates: Set<Date> = []
        var seconds: Double = 0
        for span in spans {
            guard let start = Double(span.start), let end = Double(span.end) else { continue }
            dates.insert(Date(timeIntervalSince1970: start))
            seconds += max(0, end - start)
        }
        let streak = StreakCalculator.streak(days: dates, now: now)
        return (streak, Int(seconds / 60))
    }

    // MARK: - kv

    public func setValue(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try run(
            "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            key, value
        )
    }

    public func value(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try query("SELECT v FROM kv WHERE k = ?", key) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            return text(statement, 0)
            #else
            return ""
            #endif
        }.first
    }

    // MARK: - plumbing

    private func execute(_ sql: String) throws {
        try run(sql)
    }

    /// Runs a statement for effect and ignores any rows it produces.
    ///
    /// Rows have to be tolerated, not just commands stepped once. `PRAGMA journal_mode=WAL` reports
    /// the mode it settled on, so it returns SQLITE_ROW — and demanding SQLITE_DONE here made
    /// `init` throw on every single open, which meant the store was never open at all. Nothing
    /// showed it: every call site in the app uses `try?`, so the whole of progress tracking, notes,
    /// todos and coverage quietly did nothing while the header kept reporting Day 1 of 70 forever.
    /// The unit tests could not catch it because SQLite was not importable on the build machine, so
    /// none of this code had ever run anywhere.
    private func run(_ sql: String, _ params: Any?...) throws {
        try withStatement(sql) { statement in
            try Self.bind(params, to: statement)
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return
                case SQLITE_ROW: continue
                default: throw StoreError.step(errorMessage)
                }
            }
            #endif
        }
    }

    private func query<T>(
        _ sql: String,
        _ params: Any? ...,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try withStatement(sql) { statement in
            #if canImport(SQLite3) || canImport(CSQLiteShim)
            try Self.bind(params, to: statement)
            var out: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    out.append(try map(statement))
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw StoreError.step(errorMessage)
                }
            }
            return out
            #else
            return [T]()
            #endif
        }
    }

    /// Binds values to a prepared statement.
    ///
    /// `SQLITE_TRANSIENT` matters here: Swift `String`s are not guaranteed to outlive the bind call,
    /// so without it SQLite would hold a pointer into freed memory.
    private static func bind(_ params: [Any?], to statement: OpaquePointer) throws {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, position, value)
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
        #endif
    }

    /// A single integer from the first column, or nil when there is no row.
    ///
    /// Written against `withStatement` rather than `query` because splatting one variadic into
    /// another is ambiguous once `query` has a trailing labelled parameter.
    private func scalarInt(_ sql: String, _ params: Any?...) throws -> Int? {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        return try withStatement(sql) { statement in
            try Self.bind(params, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int64(statement, 0))
        }
        #else
        return nil
        #endif
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        guard let handle else { throw StoreError.open("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StoreError.statement(sql, errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
        #else
        throw StoreError.unavailable("SQLite3 is not importable on this platform")
        #endif
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
        #else
        return ""
        #endif
    }

    private var errorMessage: String {
        #if canImport(SQLite3) || canImport(CSQLiteShim)
        guard let handle else { return "no database" }
        return String(cString: sqlite3_errmsg(handle))
        #else
        return "SQLite3 unavailable"
        #endif
    }
}


/// One session's raw start and end, as SQLite hands them back.
struct SessionSpan {
    var start: String
    var end: String
}
