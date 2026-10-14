import XCTest
@testable import StudyBuddyCore

final class BrainClientTests: XCTestCase {

    func testDeltaReadsChatCompletionContent() {
        let record = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(URLSessionBrainTransport.delta(from: record), "Hello")
    }

    func testDeltaIgnoresReasoningFrames() {
        // Some gateways stream a reasoning field before content. That is the model thinking, not
        // the tutor speaking, and reading it aloud would be both wrong and confusing.
        let record = #"data: {"choices":[{"delta":{"reasoning":"let me think"}}]}"#
        XCTAssertNil(URLSessionBrainTransport.delta(from: record))
    }

    func testDeltaIgnoresDoneSentinelAndComments() {
        XCTAssertNil(URLSessionBrainTransport.delta(from: "data: [DONE]"))
        XCTAssertNil(URLSessionBrainTransport.delta(from: ": keep-alive"))
    }

    func testDeltaHandlesNullContent() {
        let record = #"data: {"choices":[{"delta":{"content":null}}]}"#
        XCTAssertNil(URLSessionBrainTransport.delta(from: record))
    }

    func testStatusCodesMapToWhatTheUserShouldBeTold() {
        XCTAssertEqual(URLSessionBrainTransport.error(statusCode: 401), .rejectedKey(status: 401))
        XCTAssertEqual(URLSessionBrainTransport.error(statusCode: 403), .rejectedKey(status: 403))
        XCTAssertEqual(URLSessionBrainTransport.error(statusCode: 402), .outOfCredits)
        XCTAssertEqual(URLSessionBrainTransport.error(statusCode: 429, retryAfter: "30"), .rateLimited(retryAfter: "30"))
        XCTAssertEqual(URLSessionBrainTransport.error(statusCode: 500), .unreachable("HTTP 500"))
    }

    func testEveryErrorExplainsItself() {
        // The tutor shows these verbatim, so none of them may be empty or leak a raw type name.
        let errors: [BrainError] = [
            .missingKey, .rejectedKey(status: 401), .outOfCredits,
            .rateLimited(retryAfter: nil), .unreachable("timed out"), .malformedResponse("json"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) has no message")
            XCTAssertFalse(text.contains("Error"), "\(error) leaks a type name")
        }
    }

    func testFreeModelPresetsAllPointAtOneEndpoint() {
        XCTAssertEqual(BrainConfiguration.freeModels.count, 10)
        XCTAssertTrue(BrainConfiguration.freeModels.allSatisfy { $0.endpoint == BrainConfiguration.consoleBase })
        // The default has to be the zero-retention one: prompts carry the learner's own answers.
        XCTAssertEqual(BrainConfiguration.spaceBunnyFree.model, "space-bunny-free")
        // The default must not be the gateway: the free tier refuses a direct call.
        XCTAssertFalse(BrainConfiguration.spaceBunnyFree.endpoint.host?.contains("opencode.ai") ?? true)
    }
}

/// A transport that replays a canned reply, so the turn loop can be tested without a network.
private struct StubTransport: BrainTransport {
    let chunks: [String]
    let captured: Box

    final class Box: @unchecked Sendable { var messages: [ChatMessage] = []; var key = "" }

    func stream(
        configuration: BrainConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        captured.messages = messages
        captured.key = apiKey
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

final class TutorSessionTests: XCTestCase {

    private func run(
        _ said: String,
        chunks: [String],
        context: StudyContext = StudyContext()
    ) async throws -> [TutorEvent] {
        let box = StubTransport.Box()
        let transport = StubTransport(chunks: chunks, captured: box)
        let session = TutorSession(
            configuration: .spaceBunnyFree,
            transport: transport,
            prompts: PromptBuilder()
        )
        var events: [TutorEvent] = []
        for try await event in await session.send(said, apiKey: "k", context: context) {
            events.append(event)
        }
        return events
    }

    func testATurnYieldsSpeechAndSideEffects() async throws {
        let events = try await run("hello", chunks: [
            "Right, ", "let's start.", "<board title=\"Layers\" kind=\"points\">VPC</board>",
            "Which one routes?", "<log topic=\"VPC\" result=\"hit\" level=\"1\"/>",
        ])
        XCTAssertEqual(TagParser.mergingSpeech(events), [
            .speech("Right, let's start."),
            .board(BoardItem(title: "Layers", kind: "points", body: "VPC")),
            .speech("Which one routes?"),
            .log(topic: "VPC", result: "hit", level: 1),
        ])
    }

    /// The whole reason tags are stripped from what goes back into history: the model learns from
    /// what it is shown, so feeding its own tags back teaches it to emit tags in the learner's
    /// turns too, where they would be read aloud.
    func testHistoryKeepsTheReplyButStripsItsTags() async throws {
        let box = StubTransport.Box()
        let session = TutorSession(
            configuration: .spaceBunnyFree,
            transport: StubTransport(chunks: ["Hi <focus nodes=\"a\"/> there"], captured: box),
            prompts: PromptBuilder()
        )
        for try await _ in await session.send("hello", apiKey: "k", context: StudyContext()) {}
        let transcript = await session.transcript()
        XCTAssertEqual(transcript.last?.role, .assistant)
        XCTAssertEqual(transcript.last?.content, "Hi  there")
        XCTAssertFalse(transcript.last?.content.contains("<") ?? true)
    }

    func testSystemPromptLeadsAndReflectsContext() async throws {
        let box = StubTransport.Box()
        let session = TutorSession(
            configuration: .spaceBunnyFree,
            transport: StubTransport(chunks: ["ok"], captured: box),
            prompts: PromptBuilder()
        )
        let context = StudyContext(
            track: .lsat, day: 42, mode: .grill, streakDays: 9, totalMinutes: 300,
            weakTopics: [WeakTopic(topic: "Sufficient", misses: 3, hits: 1)],
            recentNotes: [SessionNote(day: 41, note: "Conditional reasoning landed")],
            openTodos: [Todo(title: "Drill assumption questions", body: "", done: false)],
            lessonText: "LESSON BODY", questionBank: "QB", skillsBlock: "SKILLS"
        )
        for try await _ in await session.send("go", apiKey: "k", context: context) {}

        let system = box.messages.first
        XCTAssertEqual(system?.role, .system)
        let text = system?.content ?? ""
        XCTAssertTrue(text.contains("day 42 of 168"), "unit and day missing")
        XCTAssertTrue(text.contains("streak: 9 day(s)"))
        XCTAssertTrue(text.contains("Sufficient (missed 3, got 1)"))
        XCTAssertTrue(text.contains("Conditional reasoning landed"))
        XCTAssertTrue(text.contains("Drill assumption questions"))
        XCTAssertTrue(text.contains("LESSON BODY"))
        XCTAssertTrue(text.contains("SKILLS"))
        // The user turn must follow the system turn.
        XCTAssertEqual(box.messages[1].role, .user)
        XCTAssertEqual(box.messages[1].content, "go")
    }

    func testAPIReturnedTurnEndsCleanly() async throws {
        // The `serial` modifier is not supported by every free gateway; a turn must still finish.
        let events = try await run("hello", chunks: ["All done."])
        XCTAssertEqual(TagParser.mergingSpeech(events), [.speech("All done.")])
    }
}
