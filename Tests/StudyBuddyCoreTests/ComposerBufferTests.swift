import XCTest
@testable import StudyBuddyCore

/// The rules that put speech into the composer.
///
/// This is the test suite for the bug where the microphone worked perfectly, the log filled with
/// `stt.partial final=true`, and the composer stayed empty. The recogniser and the text field were
/// two separate pieces of state with nothing joining them, so every layer looked healthy while the
/// one thing the learner was watching did nothing.
///
/// The view itself cannot be tested from this machine — `xtool launch` does not start apps on the
/// phone — so the decisions are extracted here and the wiring above them stays thin enough to read.
final class ComposerBufferTests: XCTestCase {

    // MARK: - the reported failure

    /// The headline case: speech arrives and the composer shows it.
    func testSpokenWordsAppearInTheComposer() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("the answer is")
        XCTAssertEqual(composer.draft, "the answer is")

        composer.heard("the answer is forty eight")
        XCTAssertEqual(composer.draft, "the answer is forty eight")
    }

    /// A partial is the recogniser revising itself, not an addition. Without replacement the
    /// composer accumulates every guess it ever made.
    func testEachPartialReplacesTheLastRatherThanAccumulating() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("multi tenancy")
        composer.heard("multi tenancy works")
        composer.heard("multi tenancy works across")
        XCTAssertEqual(composer.draft, "multi tenancy works across")
    }

    func testTheSettledTranscriptIsWhatGetsSent() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("I got S3 wrong")
        composer.settled("I got S3 wrong")
        XCTAssertEqual(composer.takeForSending(), "I got S3 wrong")
        XCTAssertEqual(composer.draft, "")
    }

    // MARK: - never destroy typed text

    func testTypedTextSurvivesAFailedRecognition() {
        var composer = ComposerBuffer()
        composer.userTyped("about cross account roles")
        composer.beginListening()
        composer.heard("and about as")
        // Recognition died here and reported nothing.
        composer.heard("")
        composer.settled("")
        XCTAssertEqual(composer.draft, "about cross account roles and about as")
    }

    func testTypedTextSurvivesSpeechThatIsDiscarded() {
        var composer = ComposerBuffer()
        composer.userTyped("ask me about VPC")
        composer.beginListening()
        composer.heard("never mind")
        composer.discardSpeech()
        XCTAssertEqual(composer.draft, "ask me about VPC")
    }

    func testSpeechAppendsToWhateverWasAlreadyTyped() {
        var composer = ComposerBuffer()
        composer.userTyped("Day 12 question")
        composer.beginListening()
        composer.heard("I missed the")
        composer.settled("I missed the second one")
        XCTAssertEqual(composer.draft, "Day 12 question I missed the second one")
    }

    /// Correcting a transcript has to stick. If the remembered prefix survived, the next utterance
    /// would bring the deleted words back.
    func testEditingAfterSpeechSticks() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("elastic beanstalk is wrong")
        composer.userTyped("elastic beanstalk is not wrong")
        composer.beginListening()
        composer.heard("it is right")
        composer.settled("it is right")
        XCTAssertEqual(composer.draft, "elastic beanstalk is not wrong it is right")
    }

    // MARK: - whitespace

    /// Recognisers emit ragged spacing and newlines. Left alone it reaches the tutor's prompt and
    /// comes back spoken with the gaps.
    func testRaggedWhitespaceFromTheRecogniserIsCollapsed() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("  I  think\n the  answer is\tB  ")
        XCTAssertEqual(composer.draft, "I think the answer is B")
    }

    func testPrefixAndSpeechAreSeparatedByExactlyOneSpace() {
        var composer = ComposerBuffer(draft: "why")
        composer.beginListening()
        composer.heard("because  ")
        XCTAssertEqual(composer.draft, "why because")
    }

    // MARK: - the send button

    func testAnEmptyComposerIsNotSendable() {
        var composer = ComposerBuffer()
        XCTAssertFalse(composer.isSendable)
        composer.userTyped("   \n ")
        XCTAssertFalse(composer.isSendable, "Whitespace must not arm the send button")
    }

    func testSentTextIsClearedAndNotResent() {
        var composer = ComposerBuffer()
        composer.userTyped("quant is hard")
        XCTAssertTrue(composer.isSendable)
        XCTAssertEqual(composer.takeForSending(), "quant is hard")
        XCTAssertFalse(composer.isSendable)
        XCTAssertEqual(composer.takeForSending(), "", "A second tap must not post the same turn again")
    }

    // MARK: - state

    func testClearingEmptiesEverything() {
        var composer = ComposerBuffer()
        composer.userTyped("hello")
        composer.beginListening()
        composer.heard("hello there")
        composer.clear()
        XCTAssertEqual(composer.draft, "")
        composer.beginListening()
        composer.heard("something else")
        XCTAssertEqual(composer.draft, "something else", "Clear must not leave a prefix behind")
    }

    func testSpeechIsDistinguishedFromTyping() {
        var composer = ComposerBuffer()
        composer.userTyped("typed")
        XCTAssertFalse(composer.lastInputWasSpeech)
        composer.beginListening()
        composer.heard("spoken")
        XCTAssertTrue(composer.lastInputWasSpeech)
        composer.settled("spoken")
        XCTAssertTrue(composer.lastInputWasSpeech)
        composer.discardSpeech()
        XCTAssertFalse(composer.lastInputWasSpeech)
    }

    /// Two utterances in a row, which is what happens when someone answers, sends, and keeps
    /// talking. The second must not inherit the first.
    func testTwoUtterancesInARowDoNotBleedIntoEachOther() {
        var composer = ComposerBuffer()
        composer.beginListening()
        composer.heard("first question")
        composer.settled("first question")
        XCTAssertEqual(composer.takeForSending(), "first question")

        composer.beginListening()
        composer.heard("second question")
        XCTAssertEqual(composer.draft, "second question")
    }
}