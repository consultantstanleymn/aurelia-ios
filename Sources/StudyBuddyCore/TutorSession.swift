import Foundation

/// Drives one tutoring turn: builds the prompt, streams the reply, and turns the reply into
/// speech plus side effects.
///
/// This is the piece the Python tutor spreads across `tutor.py`. What matters here is that the
/// turn loop is transport-agnostic and clock-free, so the whole thing — including the awkward
/// cases, like a tag arriving half-written — runs in tests on Linux.
public actor TutorSession {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var historyLimit: Int

    private let configuration: BrainConfiguration
    private let transport: any BrainTransport
    private let prompts: PromptBuilder
    private var parser = TagParser()

    public init(
        configuration: BrainConfiguration,
        transport: any BrainTransport,
        prompts: PromptBuilder,
        historyLimit: Int = 28
    ) {
        self.configuration = configuration
        self.transport = transport
        self.prompts = prompts
        self.historyLimit = historyLimit
    }

    /// Sends one thing the learner said and streams the tutor's answer back.
    ///
    /// The key is passed per call rather than held, so this actor never stores a credential: the
    /// app reads it from the Keychain on the main actor, hands it over, and it goes out of scope
    /// when the turn ends.
    public func send(
        _ said: String,
        apiKey: String,
        context: StudyContext
    ) -> AsyncThrowingStream<TutorEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    messages.append(ChatMessage(role: .user, content: said))
                    // The system prompt is rebuilt every turn rather than pinned in `messages`.
                    // It carries today's date, which mastery and coverage have advanced, and the
                    // track's day, which moves — so a prompt from turn one is wrong by turn forty.
                    let system = ChatMessage(
                        role: .system,
                        content: prompts.systemPrompt(context: context)
                    )
                    let window = Array(messages.suffix(historyLimit))
                    parser = TagParser()

                    // What the learner actually heard, and what goes back into history. Built
                    // from parsed speech events, never from the raw deltas — the raw stream still
                    // contains the tags, and feeding those back teaches the model to emit them in
                    // the learner's turns too, where they would be read aloud.
                    var spokenOnly = ""
                    var speechRun: [String] = []

                    func flushSpeech() {
                        guard !speechRun.isEmpty else { return }
                        let joined = speechRun.joined()
                        spokenOnly += joined
                        continuation.yield(.speech(joined))
                        speechRun.removeAll()
                    }

                    for try await delta in transport.stream(
                        configuration: configuration,
                        apiKey: apiKey,
                        messages: [system] + window,
                        temperature: 0.7
                    ) {

                        for event in parser.feed(delta) {
                            switch event {
                            case let .speech(text):
                                speechRun.append(text)
                            case let .board(item):
                                flushSpeech()
                                continuation.yield(.board(item))
                            case let .note(text):
                                flushSpeech()
                                continuation.yield(.note(text))
                            case let .todo(title, body):
                                flushSpeech()
                                continuation.yield(.todo(title: title, body: body))
                            case let .log(topic, result, level):
                                flushSpeech()
                                continuation.yield(.log(topic: topic, result: result, level: level))
                            case let .focus(nodes):
                                flushSpeech()
                                continuation.yield(.focus(nodes: nodes))
                            case let .layout(board):
                                flushSpeech()
                                continuation.yield(.layout(board: board))
                            case let .covered(section):
                                flushSpeech()
                                continuation.yield(.covered(section: section))
                            case .dayDone:
                                flushSpeech()
                                continuation.yield(.dayDone)
                            }
                        }
                    }

                    for event in parser.flush() {
                        if case let .speech(text) = event {
                            speechRun.append(text)
                        } else {
                            flushSpeech()
                            continuation.yield(event)
                        }
                    }
                    flushSpeech()

                    // What goes back into history is the reply with its tags stripped. Feeding the
                    // raw reply back would teach the model that its own tags are the expected
                    // output, and they would start arriving in the user's turns.
                    messages.append(ChatMessage(role: .assistant, content: spokenOnly))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The visible conversation, for the caption history and for saving a session.
    public func transcript() -> [ChatMessage] { messages }

    public func clear() {
        messages.removeAll()
        parser = TagParser()
    }
}
