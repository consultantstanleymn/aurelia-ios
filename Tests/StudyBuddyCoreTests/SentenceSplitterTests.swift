import XCTest
@testable import StudyBuddyCore

/// How a streaming reply becomes speakable sentences.
///
/// The tutor's answer arrives token by token and is spoken as it goes, sentence by sentence, so the
/// app is constantly asking "have I got a whole sentence yet?". That question has one property that
/// matters above all others: **a sentence already emitted must never be rewritten.** If it changes,
/// the tutor says something, retracts it, and says something else, and the learner hears a tutor
/// that cannot commit to a word.
///
/// This drives the whole caption stream, and it had no tests at all.
final class SentenceSplitterTests: XCTestCase {

    // MARK: - the basic contract

    func testOneSentence() {
        XCTAssertEqual(SentenceSplitter.split("Hello there."), ["Hello there."])
    }

    func testTwoSentences() {
        XCTAssertEqual(
            SentenceSplitter.split("Hello there. How are you?"),
            ["Hello there.", "How are you?"]
        )
    }

    func testExclamationAndQuestionBothEndASentence() {
        XCTAssertEqual(
            SentenceSplitter.split("That is right! Really?"),
            ["That is right!", "Really?"]
        )
    }

    /// Nothing is said yet, so nothing comes out. The caller relies on this to stay quiet rather
    /// than speak an empty string.
    func testEmptyAndWhitespaceProduceNothing() {
        XCTAssertEqual(SentenceSplitter.split(""), [])
        XCTAssertEqual(SentenceSplitter.split("   \n  "), [])
    }

    /// A sentence that has not finished yet is still returned, and the caller holds it back as the
    /// last element. Dropping it would mean the tail of every reply was never spoken.
    func testAnUnfinishedTailIsReturnedRatherThanDropped() {
        XCTAssertEqual(
            SentenceSplitter.split("The answer is on the board. And th"),
            ["The answer is on the board.", "And th"]
        )
    }

    // MARK: - things that only look like a full stop

    /// The port of the Python tutor's abbreviation list. Splitting after "e.g." would read as
    /// "E. G." and cut the sentence in half.
    func testAbbreviationsDoNotEndASentence() {
        XCTAssertEqual(
            SentenceSplitter.split("Use the right one, e.g. an S3 bucket."),
            ["Use the right one, e.g. an S3 bucket."]
        )
        XCTAssertEqual(
            SentenceSplitter.split("Compare them, i.e. look at the region."),
            ["Compare them, i.e. look at the region."]
        )
    }

    func testAbbreviationsOnlyCountAtTheEndOfAText() {
        let parts = SentenceSplitter.split("That is Mr. Wrong. Try again.")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1], "Try again.")
    }

    /// A deliberate trade, pinned here so it is a decision rather than a surprise.
    ///
    /// "no" is on the abbreviation list, so "The answer is no. Explain why." does not split after
    /// "no." — the two sentences arrive as one caption. The bias is deliberate and always towards
    /// not splitting: a merged caption is still all spoken and still reads as prose, whereas
    /// splitting where it should not gives "E." and "G." as separate captions, with a pause the
    /// tutor never intended. A slightly late caption is cheaper than a wrong one.
    func testAnAmbiguousAbbreviationMergesRatherThanSplits() {
        XCTAssertEqual(
            SentenceSplitter.split("The answer is no. Explain why."),
            ["The answer is no. Explain why."]
        )
    }

    // MARK: - numbers, versions and ranges

    /// The one that mattered. A tutor for this material says CIDR ranges constantly, and the old
    /// splitter turned this into eight spoken fragments: "ten. zero. zero. zero. slash eight."
    func testACidrRangeIsOneSentence() {
        XCTAssertEqual(
            SentenceSplitter.split("The range is 10.0.0.0/8 so any address inside it works."),
            ["The range is 10.0.0.0/8 so any address inside it works."]
        )
    }

    func testDecimalsAndVersionNumbersSurvive() {
        XCTAssertEqual(
            SentenceSplitter.split("It costs 0.023 per GB. Use version v1.0.44 or newer."),
            ["It costs 0.023 per GB.", "Use version v1.0.44 or newer."]
        )
    }

    func testASentenceEndingInANumberStillEnds() {
        XCTAssertEqual(
            SentenceSplitter.split("The answer is 3. Now try 4.5."),
            ["The answer is 3.", "Now try 4.5."]
        )
    }

    /// An ellipsis is a pause the tutor should take, so it does end a sentence — even though the
    /// next one then starts in lower case. What matters is that no text is lost.
    func testEllipsisIsAPause() {
        let parts = SentenceSplitter.split("Wait... what did you say?")
        XCTAssertEqual(parts.joined(separator: " "), "Wait... what did you say?")
    }

    func testDottedInitialismsSurvive() {
        XCTAssertEqual(
            SentenceSplitter.split("Compare U.S. East with U.K. West."),
            ["Compare U.S. East with U.K. West."]
        )
    }

    /// Blank lines are what a model's markdown reply arrives with, and one must never come back
    /// as a sentence — the tutor would say it, and the caption would be an empty bubble.
    func testBlankLinesDoNotBecomeSentences() {
        XCTAssertEqual(SentenceSplitter.split("One.\n\n\nTwo."), ["One.", "Two."])
        XCTAssertEqual(SentenceSplitter.split("\n\n"), [])
    }

    /// A closing quote or bracket belongs to the sentence it ends, not after it.
    func testClosingQuotesAndBracketsStayWithTheSentence() {
        XCTAssertEqual(
            SentenceSplitter.split("He said \"stop.\" Then he left."),
            ["He said \"stop.\"", "Then he left."]
        )
        XCTAssertEqual(
            SentenceSplitter.split("Call it (say this.) Then move on."),
            ["Call it (say this.)", "Then move on."]
        )
    }

    // MARK: - streaming stability

    /// The property the whole feature rests on. The app feeds an ever-growing buffer, so at every
    /// step the sentences it has already spoken must be byte-identical to before. This walks a
    /// reply one character at a time and checks it after every single character.
    ///
    /// The reply deliberately contains every trap at once: an abbreviation, a CIDR range, an
    /// exclamation, a decimal and a closing quote.
    func testEmittedSentencesNeverChangeAsMoreTextArrives() {
        let reply = "You missed the subnet. e.g. 10.0.0.0/8 is the range. That is why! He said \"stop.\""
        var spoken: [String] = []
        for length in 1...reply.count {
            let prefix = String(reply.prefix(length))
            // Everything except the last element is finished, and finished means permanent.
            let settled = Array(SentenceSplitter.split(prefix).dropLast())
            if settled.count >= spoken.count {
                XCTAssertEqual(
                    Array(settled.prefix(spoken.count)),
                    spoken,
                    "a settled sentence changed after \(length) characters"
                )
                spoken = settled
            } else {
                XCTFail("sentences were retracted at \(length) characters: \(settled) after \(spoken)")
            }
        }
        // At the end, three are released and the fourth is still pending: the caller holds the
        // last element back because it may still be growing. What must hold is that the released
        // prefix is exactly the settled prefix of the whole reply, and that nothing was lost.
        let finalParts = SentenceSplitter.split(reply)
        XCTAssertEqual(finalParts.count, 4)
        XCTAssertEqual(spoken, Array(finalParts.dropLast()))
        XCTAssertEqual(finalParts.joined(separator: " "), reply)
    }

    /// The same walk, but through the chunk boundaries a token stream actually delivers, checking
    /// that nothing is lost or spoken twice as sentences are handed off one at a time.
    func testChunkBoundariesDoNotCreateSentences() {
        let whole = "One. Two. Three. Four."
        let chunks = ["On", "e. T", "wo. Thr", "ee. Four", ".", ""]

        var finished: [String] = []
        var pending = ""
        for chunk in chunks {
            pending += chunk
            let parts = SentenceSplitter.split(pending)
            finished += parts.dropLast()
            pending = parts.last ?? ""
        }
        // The last sentence is still pending; the turn end flushes it.
        finished += SentenceSplitter.split(pending)

        XCTAssertEqual(finished, ["One.", "Two.", "Three.", "Four."])
        XCTAssertEqual(SentenceSplitter.split(whole), finished)
    }
}