#if os(iOS) || os(macOS)
import Foundation
import StudyBuddyCore
import UserNotifications

/// Daily study reminders, on the device.
///
/// The Python tutor kept a schedule in `~/.config/study-mentor/schedule.json` and the desktop crab
/// widget read it. On a phone there is no widget and no shared file, so the schedule lives here and
/// `UNUserNotificationCenter` does what the widget did.
///
/// The defaults are the Python's exactly — AWS at 19:30 on weekdays, LSAT 20:30, quant 21:00,
/// only AWS enabled — so the app reminds about the same thing at the same time as the thing it
/// replaces.
@MainActor
@Observable
final class Reminders {

    struct Entry: Identifiable, Equatable, Codable, Sendable {
        var id: String
        var track: Track
        /// "HH:mm" in the device's timezone.
        var time: String
        /// Weekday numbers, Sunday = 0, matching `Calendar.component(.weekday)`.
        var days: Set<Int>
        var enabled: Bool

        var hour: Int { Int(time.prefix(2)) ?? 19 }
        var minute: Int { Int(time.suffix(2)) ?? 30 }
    }

    private(set) var entries: [Entry] = Reminders.defaults
    private(set) var authorisation: UNAuthorizationStatus = .notDetermined

    private let centre = UNUserNotificationCenter.current()
    private static let storeKey = "aurelia.reminders.entries"

    var weekdays: Set<Int> { [2, 3, 4, 5, 6] }

    static let defaults: [Entry] = [
        Entry(id: "aws", track: .aws, time: "19:30", days: [2, 3, 4, 5, 6], enabled: true),
        Entry(id: "lsat", track: .lsat, time: "20:30", days: [2, 3, 4, 5, 6], enabled: false),
        Entry(id: "quant", track: .quant, time: "21:00", days: [2, 3, 4, 5, 6], enabled: false),
    ]

    init() {
        load()
    }

    // MARK: - permission

    func refreshAuthorisation() async {
        let settings = await centre.notificationSettings()
        authorisation = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorisation() async -> Bool {
        do {
            let granted = try await centre.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorisation()
            DiagLog.event("reminders.authorisation", ["granted": granted])
            if granted { await applyAll() }
            return granted
        } catch {
            DiagLog.event("reminders.authorisationFailed", ["error": error.localizedDescription])
            return false
        }
    }

    // MARK: - storage

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let saved = try? JSONDecoder().decode([Entry].self, from: data),
              !saved.isEmpty
        else { return }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    func update(_ entry: Entry) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
        await apply(entry)
    }

    func setEnabled(_ enabled: Bool, for id: String) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        save()
        await apply(entries[index])
    }

    // MARK: - scheduling

    /// Re-registers everything. Called after permission is granted, since requests made while
    /// unauthorised are dropped silently and would leave the learner with no reminders and no clue.
    func applyAll() async {
        for entry in entries { await apply(entry) }
    }

    func apply(_ entry: Entry) async {
        let identifier = Self.identifier(for: entry)
        centre.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard entry.enabled, authorisation == .authorized else {
            DiagLog.event("reminders.skipped", ["id": entry.id, "enabled": entry.enabled, "auth": authorisation.rawValue])
            return
        }

        // One request per weekday: a repeating calendar trigger cannot express "weekdays only".
        for weekday in entry.days.sorted() {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = entry.hour
            components.minute = entry.minute

            let content = UNMutableNotificationContent()
            content.title = title(for: entry.track)
            content.body = body(for: entry.track)
            content.sound = .default
            content.userInfo = ["track": entry.track.rawValue]

            let request = UNNotificationRequest(
                identifier: "\(identifier).\(weekday)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
            do {
                try await centre.add(request)
            } catch {
                DiagLog.event("reminders.addFailed", ["id": entry.id, "weekday": weekday, "error": error.localizedDescription])
            }
        }
        DiagLog.event("reminders.applied", ["id": entry.id, "days": entry.days.count, "time": entry.time])
    }

    func removeAll() {
        // Every weekday of every entry, enabled or not: a reminder that was switched off still has
        // a pending request until it is explicitly removed, and only its identifier cancels it.
        let identifiers = entries.flatMap { entry in
            (0 ... 7).map { "\(Self.identifier(for: entry)).\($0)" }
        }
        centre.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func identifier(for entry: Entry) -> String { "aurelia.reminder.\(entry.id)" }

    // MARK: - copy

    private func title(for track: Track) -> String {
        switch track {
        case .aws: return "AWS SA Pro"
        case .lsat: return "LSAT"
        case .quant: return "Quant"
        }
    }

    /// Says what to do rather than "you have a reminder", which is what the widget's line did.
    private func body(for track: Track) -> String {
        switch track {
        case .aws: return "Ten minutes on today's AWS chapter beats an hour on Sunday."
        case .lsat: return "One passage today. Timing is the part you cannot practise on Sunday."
        case .quant: return "One quant topic. Keep the streak alive."
        }
    }

    /// The next fire time for an entry, for the settings list. Pure so it can be tested.
    nonisolated static func nextFire(
        time: String,
        weekdays: Set<Int>,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let hour = Int(time.prefix(2)) ?? 19
        let minute = Int(time.suffix(2)) ?? 30
        guard !weekdays.isEmpty else { return nil }

        for offset in 0 ... 8 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            guard weekdays.contains(weekday) else { continue }
            var parts = calendar.dateComponents([.year, .month, .day], from: candidate)
            parts.hour = hour
            parts.minute = minute
            guard let date = calendar.date(from: parts) else { continue }
            if date > now { return date }
        }
        return nil
    }
}
#endif
