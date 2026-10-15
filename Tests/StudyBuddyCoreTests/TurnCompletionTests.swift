import XCTest
@testable import StudyBuddyCore

/// The counter the turn loop waits on.
///
/// The tutor speaks a reply sentence by sentence, and `isSpeaking` has to come back down when the
/// last one finishes. This counter is what says "last one". Two mistakes are possible here and both
/// are silent: counting down too far never clears the speaking indicator, and calling the finish
/// handler twice clears it early — the learner interrupts a tutor who is still mid-sentence.
///
/// It counts down from several threads at once, because the voice engines call back off the main
/// queue, so the tests hammer it concurrently rather than trusting the lock by inspection.
final class TurnCompletionTests: XCTestCase {

    func testNotCompleteUntilTheLastSentenceLands() {
        let turn = TurnCompletion(expected: 3)
        XCTAssertFalse(turn.isComplete)

        var calls = 0
        turn.sentenceFinished { calls += 1 }
        turn.sentenceFinished { calls += 1 }
        XCTAssertFalse(turn.isComplete, "two of three is not done")
        XCTAssertEqual(calls, 0)

        turn.sentenceFinished { calls += 1 }
        XCTAssertTrue(turn.isComplete)
        XCTAssertEqual(calls, 1, "the finish handler runs once, on the last sentence")
    }

    /// A reply of one sentence is the common case and must not need a second one to complete.
    func testASingleSentenceCompletesImmediately() {
        let turn = TurnCompletion(expected: 1)
        var calls = 0
        turn.sentenceFinished { calls += 1 }
        XCTAssertTrue(turn.isComplete)
        XCTAssertEqual(calls, 1)
    }

    /// Extra callbacks after completion are ignored. Audio engines do finish more than once — a
    /// cancelled sentence still reports — and a second call would clear the speaking state while
    /// the tutor was still going.
    func testExtraFinishesAfterCompletionAreIgnored() {
        let turn = TurnCompletion(expected: 2)
        var calls = 0
        turn.sentenceFinished { calls += 1 }
        turn.sentenceFinished { calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(turn.isComplete)
    }

    func testCancellingEndsTheTurnWithoutFiringTheFinishHandler() {
        let turn = TurnCompletion(expected: 3)
        var calls = 0
        turn.cancel()
        XCTAssertTrue(turn.isComplete)

        turn.sentenceFinished { calls += 1 }
        XCTAssertEqual(calls, 0, "an interrupted turn must not run the finish handler")
    }

    func testCancellingTwiceIsHarmless() {
        let turn = TurnCompletion(expected: 3)
        turn.cancel()
        turn.cancel()
        XCTAssertTrue(turn.isComplete)
    }

    /// Concurrent finishes, which is what several queued audio buffers produce. Exactly one must
    /// run the handler however many callbacks land.
    func testConcurrentFinishesRunTheHandlerExactlyOnce() {
        for expected in [1, 2, 8, 32] {
            let turn = TurnCompletion(expected: expected)
            let counter = Counter()
            DispatchQueue.concurrentPerform(iterations: expected * 4) { _ in
                turn.sentenceFinished { counter.bump() }
            }
            XCTAssertEqual(counter.value, 1, "\(expected) sentences should fire the handler once")
            XCTAssertTrue(turn.isComplete)
        }
    }

    /// A counter small enough to be in a test, so the assertion above is about the real thing.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}