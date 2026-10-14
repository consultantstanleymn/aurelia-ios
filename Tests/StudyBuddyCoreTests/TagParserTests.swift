import XCTest
@testable import StudyBuddyCore

/// The Python original has no tests for `TagParser`, and it is the one piece of the tutor that is
/// genuinely hard to get right: it runs on a stream split at arbitrary points, and every bug in it
/// is either invisible (a dropped whiteboard) or embarrassing (half a tag read aloud).
///
/// These cases are checked against the Python implementation's real behaviour, not against what
/// seems reasonable. Where the two disagree, the Python is right — it is what the prompt was
/// written against and what the deployed tutor has been running against.
///
/// Assertions are on speech *merged*, because that is the contract the caption view and the voice
/// consume. The parser itself deliberately emits `5 `, `<`, ` 7` as three events.
final class TagParserTests: XCTestCase {

    /// The parser plus the merge the UI applies, which is the shape a caption actually sees.
    private func merged(_ events: [TutorEvent]) -> [TutorEvent] {
        TagParser.mergingSpeech(events)
    }

    // MARK: - plain speech

    func testSpeechPassesThrough() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("Good morning.")), [.speech("Good morning.")])
    }

    func testSpeechAndTagInterleave() {
        var parser = TagParser()
        let events = merged(parser.feed("Look at this.<focus nodes=\"a,b\"/>Done."))
        XCTAssertEqual(events, [
            .speech("Look at this."),
            .focus(nodes: "a,b"),
            .speech("Done."),
        ])
    }

    // MARK: - the case that breaks naive ports

    func testTagSplitAcrossChunksIsHeldBack() {
        var parser = TagParser()
        // "boa" is not yet a tag, so it must not be spoken — but the text before the bracket
        // legitimately already went out, which is exactly what the Python does.
        XCTAssertEqual(merged(parser.feed("Look: <boa")), [.speech("Look: ")])
        XCTAssertEqual(merged(parser.feed("rd kind=\"points\">A</board>")), [
            .board(BoardItem(title: "", kind: "points", body: "A")),
        ])
    }

    func testSelfClosingTagSplitAcrossChunks() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<fo")), [])
        XCTAssertEqual(merged(parser.feed("cus nodes=\"x\"/>")), [.focus(nodes: "x")])
    }

    func testStrayLessThanIsSpokenNotSwallowed() {
        var parser = TagParser()
        // Not a tag prefix. Must be read aloud, and must not swallow the rest of the reply.
        XCTAssertEqual(merged(parser.feed("5 < 7")), [.speech("5 < 7")])
    }

    func testUnterminatedTagFlushesAsSpeech() {
        var parser = TagParser()
        let streamed = parser.feed("and then <bo") + parser.flush()
        XCTAssertEqual(merged(streamed), [.speech("and then <bo")])
    }

    // MARK: - boundaries

    func testTagNameMustEndOnWordBoundary() {
        var parser = TagParser()
        // <boardish> is not <board>, so it must be spoken rather than parsed.
        XCTAssertEqual(merged(parser.feed("<boardish>")), [.speech("<boardish>")])
    }

    func testBoardDefaultsWhenAttributesAreMissing() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<board>Hello</board>")), [
            .board(BoardItem(title: "", kind: "points", body: "Hello")),
        ])
    }

    // MARK: - payload handling

    func testEscapedNewlinesAreUnescaped() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<todo title=\"Home\">one\\ntwo</todo>")),
                       [.todo(title: "Home", body: "one\ntwo")])
    }

    func testAttributesAreParsed() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<log topic=\"RTO\" result=\"miss\" level=\"2\"/>")),
                       [.log(topic: "RTO", result: "miss", level: 2)])
    }

    func testNonNumericLevelBecomesZero() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<log topic=\"x\" level=\"high\"/>")),
                       [.log(topic: "x", result: "hit", level: 0)])
    }

    func testDayDoneHasNoAttributes() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<day_done/>")), [.dayDone])
    }

    func testSingleQuotedAttributesAreAccepted() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<layout board='wide'/>")), [.layout(board: "wide")])
    }

    // MARK: - calc

    func testCalcIsEvaluatedAndSpoken() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<calc>1250*4</calc>")), [.speech("5,000")])
    }

    func testCalcWithFunction() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<calc>sqrt(144)</calc>")), [.speech("12")])
    }

    func testCalcThatCannotBeEvaluatedFallsBack() {
        var parser = TagParser()
        XCTAssertEqual(merged(parser.feed("<calc>import os</calc>")), [.speech("that number")])
    }

    // MARK: - a realistic reply, the shape the prompt actually asks for

    func testFullReplyShape() {
        var parser = TagParser()
        let stream = "Right, let's start."
            + "<board title=\"Layers\" kind=\"points\">VPC\\nSubnet\\nRoute table</board>"
            + "Which one routes between them?"
            + "<log topic=\"VPC\" result=\"hit\" level=\"1\"/>"

        var events = parser.feed(stream)
        events += parser.flush()

        XCTAssertEqual(merged(events), [
            .speech("Right, let's start."),
            .board(BoardItem(title: "Layers", kind: "points", body: "VPC\nSubnet\nRoute table")),
            .speech("Which one routes between them?"),
            .log(topic: "VPC", result: "hit", level: 1),
        ])
    }

    /// The same reply delivered one character at a time must produce identical events. If it does
    /// not, the buffering is wrong and speech will contain fragments of tags on a bad network.
    func testChunkingDoesNotChangeTheResult() {
        let stream = "Right, let's start."
            + "<board title=\"Layers\" kind=\"points\">VPC\\nSubnet</board>"
            + "Which one routes between them?"
            + "<log topic=\"VPC\" result=\"hit\" level=\"1\"/>"

        var whole = TagParser()
        let expected = TagParser.mergingSpeech(whole.feed(stream) + whole.flush())

        var characterAtATime = TagParser()
        var actual: [TutorEvent] = []
        for character in stream {
            actual += characterAtATime.feed(String(character))
        }
        actual += characterAtATime.flush()

        XCTAssertEqual(TagParser.mergingSpeech(actual), expected)
    }

    func testMergingLeavesSideEffectsInPlace() {
        var parser = TagParser()
        let events = parser.feed("one<focus nodes=\"a\"/>two<focus nodes=\"b\"/>three")
        XCTAssertEqual(merged(events), [
            .speech("one"), .focus(nodes: "a"), .speech("two"),
            .focus(nodes: "b"), .speech("three"),
        ])
    }
}

final class SafeCalcTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(SafeCalc.speak("2+2"), "4")
        XCTAssertEqual(SafeCalc.speak("10/4"), "2.5")
        XCTAssertEqual(SafeCalc.speak("2^10"), "1,024")
    }

    func testSpokenFormatting() {
        XCTAssertEqual(SafeCalc.spoken(-1250), "negative 1,250")
        XCTAssertEqual(SafeCalc.spoken(1250), "1,250")
        XCTAssertEqual(SafeCalc.spoken(1500.25), "1,500.2")
    }

    func testRejectsAnythingOutsideTheAllowList() {
        // No names, no calls that escape, no properties, no partial expressions.
        XCTAssertEqual(SafeCalc.speak("__import__"), "that number")
        XCTAssertEqual(SafeCalc.speak("1 +"), "that number")
        XCTAssertEqual(SafeCalc.speak("1/0"), "that number")
    }
}
