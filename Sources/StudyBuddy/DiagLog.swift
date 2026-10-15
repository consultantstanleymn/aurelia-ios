#if canImport(Foundation)
import Foundation

/// Writes what the app is doing to a file I can pull off the device.
///
/// This exists because NSLog is not observable here. `xtool` cannot attach a debugger on this
/// device — it fails the same way on the known-good openGym build — so stderr goes nowhere, and
/// there is no Developer Disk Image to screenshot the screen with. The device syslog had nothing
/// in it either. A file in the app container is the one channel that survives both limits, and
/// `ifuse --documents <bundle-id>` reads it.
///
/// Verbose on purpose. Every permission decision, every audio-engine state change, every turn of
/// the tutor and every network failure lands here, because a bug that only shows itself as "the
/// button does nothing" cannot be reasoned about — it has to be observed.
///
/// The file is capped: appending forever would fill the device, and the interesting part is always
/// the most recent one.
enum DiagLog {
    private static let name = "aurelia.log"
    private static let cap = 256 * 1024
    private static let lock = NSLock()

    static var isEnabled: Bool { true }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp())  \(message)\n"
        // Also to the system log, so whichever channel is being watched shows something.
        NSLog("%@", line.trimmingCharacters(in: .newlines))

        guard let url = fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing.utf8.count + line.utf8.count > cap {
            // Keep the newest half, drop the oldest.
            let tail = String(existing.suffix(cap / 2))
            try? tail.write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Deliberately stringly-typed. This is a diagnostic sink, not an API, and making every call
    /// site construct a payload type would only get in the way of adding the next line quickly.
    static func event(_ name: String, _ detail: [String: Any] = [:]) {
        guard !detail.isEmpty else { return write("· \(name)") }
        let body = detail
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        write("· \(name)  \(body)")
    }

    static var path: String { fileURL()?.path ?? "(no container)" }

    static func fileURL() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return documents.appendingPathComponent(name)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
#endif
