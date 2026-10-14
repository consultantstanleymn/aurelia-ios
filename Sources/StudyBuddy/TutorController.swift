import Foundation
import Observation
import StudyBuddyCore

/// One line in the conversation.
struct Caption: Identifiable, Equatable {
    enum Who: Equatable { case tutor, learner, system }
    let id = UUID()
    var who: Who
    var text: String
    /// Set while the tutor is still writing this line, so the view can show it differently.
    var isStreaming = false
}

/// Holds the conversation and drives one turn at a time.
///
/// The turn is the interesting part: the brain streams, the parser turns that stream into speech
/// and side effects, and the voice speaks each sentence as it becomes complete. Doing it in that
/// order is what stops the tutor from going silent for four seconds while a model writes.
@MainActor
@Observable
final class TutorController {
    private(set) var captions: [Caption] = []
    private(set) var isThinking = false
    private(set) var board: BoardItem?
    private(set) var todos: [Todo] = []
    private(set) var notes: [SessionNote] = []
    private(set) var lastError: String?
    /// True while the tutor's voice is playing, used to show the speaking indicator.
    private(set) var isSpeaking = false

    var track: Track = .aws
    var mode: StudyMode = .teach
    var day: Int = 1

    private var session: TutorSession?
    private let voice: SpeechEngine
    private var turn: TurnCompletion?
    /// Sentences waiting to be spoken, and the run of speech still arriving.
    private var speechRun: [String] = []
    private var sentenceBuffer = ""

    init(voice: SpeechEngine) {
        self.voice = voice
    }

    // MARK: - configuration

    /// Rebuilds the session when the brain or the track changes. Cheaper than a turn is lost.
    func configure(brain: BrainConfiguration, transport: any BrainTransport) {
        session = TutorSession(
            configuration: brain,
            transport: transport,
            prompts: PromptBuilder()
        )
    }

    func context() -> StudyContext {
        StudyContext(
            track: track,
            day: day,
            mode: mode,
            weakTopics: [],
            recentNotes: notes,
            openTodos: todos.filter { !$0.done }
        )
    }

    // MARK: - the turn

    func send(_ said: String, apiKey: String) async {
        guard let session, !isThinking else { return }
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        captions.append(Caption(who: .learner, text: trimmed))
        isThinking = true
        lastError = nil

        do {
            for try await event in await session.send(trimmed, apiKey: apiKey, context: context()) {
                handle(event)
            }
            finishTurn()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captions.append(Caption(who: .system, text: lastError ?? "Something went wrong."))
            isThinking = false
        }
    }

    private func handle(_ event: TutorEvent) {
        switch event {
        case let .speech(text):
            // Buffer until a sentence is complete, so the voice has something speakable to say.
            sentenceBuffer += text
            let sentences = SentenceSplitter.split(sentenceBuffer)
            guard sentences.count > 1 else { return }
            // The last element may still be growing, so keep it back.
            let ready = Array(sentences.dropLast())
            sentenceBuffer = sentences.last ?? ""
            for sentence in ready { enqueue(sentence) }

        case let .board(item):
            board = item
        case let .note(text):
            notes.append(SessionNote(day: day, note: text))
        case let .todo(title, body):
            todos.append(Todo(title: title, body: body, done: false))
        case .log, .focus, .layout, .covered:
            // Recorded by the progress store, which is not wired in yet; deliberately inert here
            // rather than faked, so nothing shows a number the app did not actually persist.
            break
        case .dayDone:
            captions.append(Caption(who: .system, text: "Day \(day) done."))
        }
    }

    private func enqueue(_ sentence: String) {
        guard !sentence.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if captions.last?.who == .tutor, captions.last?.isStreaming == true {
            captions[captions.count - 1].text += " " + sentence
        } else {
            captions.append(Caption(who: .tutor, text: sentence, isStreaming: true))
        }
        isSpeaking = true
        voice.speak(sentence) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.turn?.isComplete == true { self.isSpeaking = false }
            }
        }
    }

    private func finishTurn() {
        if !sentenceBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            enqueue(sentenceBuffer)
            sentenceBuffer = ""
        }
        captions = captions.map { caption in
            var caption = caption
            caption.isStreaming = false
            return caption
        }
        isThinking = false
    }

    /// Cuts the tutor off. Balking mid-sentence is normal, not exceptional.
    func interrupt() {
        voice.stop()
        turn?.cancel()
        turn = nil
        sentenceBuffer = ""
        isSpeaking = false
        isThinking = false
        finishTurn()
    }

    func reset() {
        interrupt()
        captions.removeAll()
        board = nil
        lastError = nil
        Task { await session?.clear() }
    }
}
