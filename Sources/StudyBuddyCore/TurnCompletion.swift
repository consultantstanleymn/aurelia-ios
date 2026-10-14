import Foundation

/// Holds a process-safe count of outstanding sentences and nothing else.
///
/// Extracted from `ChatterboxVoice` because it is the only piece of that file with real logic and
/// it is what the turn loop waits on, so it is worth testing on its own.
public final class TurnCompletion: @unchecked Sendable {
    private var remaining: Int
    private var finished = false
    private let lock = NSLock()

    public init(expected: Int) {
        remaining = expected
    }

    public var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Records one sentence finishing. Calls `body` exactly once, when the last one lands.
    public func sentenceFinished(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        remaining -= 1
        guard remaining <= 0 else { return }
        finished = true
        body()
    }

    /// Ends the turn early, when the learner talks over the tutor or the app backgrounds.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
    }
}
