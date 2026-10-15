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
        /// Weekday numbers as `Calendar` counts them: Sunday = 1, Saturday = 7. The same numbering
        /// `UNCalendarNotificationTrigger` uses, so the weekday written into a notification and the
        /// weekday checked when working out when it next fires cannot drift apart. The defaults
        /// below are 2 through 6, which is Monday to Friday.
        var days: Set<Int>
        var enabled: Bool

        var hour: Int { ReminderSchedule.time(time).hour }
        var minute: Int { ReminderSchedule.time(time).minute }
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
        // Every weekday variant has to go, not just the bare identifier. The requests are added as
        // "<id>.<weekday>" but were cancelled as "<id>", which matches nothing — so changing a time
        // added a second reminder and left the old one pending. The learner ends up being reminded
        // about the same chapter twice a day, at a time they had already turned off.
        centre.removePendingNotificationRequests(withIdentifiers: Self.identifiers(for: entry))
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
                identifier: "\(Self.identifier(for: entry)).\(weekday)",
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
        let identifiers = entries.flatMap { Self.identifiers(for: $0) }
        centre.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func identifier(for entry: Entry) -> String { "aurelia.reminder.\(entry.id)" }

    /// Every identifier a single entry can have pending, one per weekday.
    ///
    /// Sunday is 1 and Saturday is 7 in `Calendar`, which is also how `UNCalendarNotificationTrigger`
    /// numbers them, so the range covers every weekday that can ever be scheduled. Zero is included
    /// so a bad write cannot leave a request behind that nothing can cancel.
    static func identifiers(for entry: Entry) -> [String] {
        (0 ... 7).map { "\(identifier(for: entry)).\($0)" }
    }

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

    /// The next fire time for an entry, for the settings list. Pure so it can be tested — the
    /// arithmetic is in Core, where the suite can reach it.
    nonisolated static func nextFire(
        time: String,
        weekdays: Set<Int>,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        ReminderSchedule.nextFire(time: time, weekdays: weekdays, now: now, calendar: calendar)
    }
}
#endif
