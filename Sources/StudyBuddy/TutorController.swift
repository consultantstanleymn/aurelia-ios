#if canImport(SwiftUI)
import SwiftUI
import StudyBuddyCore

/// Holds the conversation and drives one turn at a time.
///
/// This is where the pieces meet: the content store decides what the tutor can teach today, the
/// progress store decides what it should re-test, and the turn's events feed back into both. Until
/// this was wired the app could talk and nothing it said changed anything.
@MainActor
@Observable
final class TutorController {
    private(set) var captions: [Caption] = []
    private(set) var isThinking = false
    var board: BoardShape?
    private(set) var boardFocus: Set<String> = []
    private(set) var isSpeaking = false
    private(set) var lastError: String?

    var track: Track = .aws
    var mode: StudyMode = .teach
    private(set) var day: Int = 1
    private(set) var streakDays = 0
    private(set) var totalMinutes = 0
    private(set) var coveredCount = 0

    /// The learner can move between days; the tutor opens on the first unfinished one.
    var dayForPrompt: Int { day }

    private var session: TutorSession?
    private let voice: SpeechEngine
    private var turn: TurnCompletion?
    private var sentenceBuffer = ""
    private let content = ContentStore.shared
    private var progress: ProgressStore?
    private let prompts = PromptBuilder()

    init(voice: SpeechEngine) {
        self.voice = voice
    }

    // MARK: - setup

    /// Opens the store and lands on the first day not yet done.
    func prepare() async {
        if progress == nil {
            // Application Support rather than Documents: the database is not something the
            // learner needs to see over USB, and Documents is exposed for file sharing.
            if let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let directory = base.appendingPathComponent("Aurelia", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("progress.sqlite")
                progress = try? ProgressStore(path: file.path)
                DiagLog.event("progress.opened", ["path": file.path, "ok": progress != nil])
            }
        }
        await reloadProgress()
    }

    func configure(brain: BrainConfiguration, transport: any BrainTransport) {
        DiagLog.event("brain.configured", ["provider": brain.provider, "model": brain.model, "host": brain.host])
        session = TutorSession(
            configuration: brain,
            transport: transport,
            prompts: prompts
        )
    }

    private func reloadProgress() async {
        guard let progress else { return }
        let raw = track.rawValue
        day = (try? progress.nextDay(track: raw, total: track.totalUnits)) ?? 1
        let stats = (try? progress.stats(track: raw)) ?? (streak: 0, minutes: 0)
        streakDays = stats.streak
        totalMinutes = stats.minutes
        coveredCount = (try? progress.coveredSections(track: raw, day: day))?.count ?? 0
    }

    func select(day newDay: Int) async {
        day = min(max(newDay, 1), track.totalUnits)
        coveredCount = (try? progress?.coveredSections(track: track.rawValue, day: day))?.count ?? 0
        DiagLog.event("ui.selectDay", ["track": track.rawValue, "day": day])
    }

    func select(track newTrack: Track) async {
        track = newTrack
        await reloadProgress()
        DiagLog.event("ui.selectTrack", ["track": newTrack.rawValue, "day": day])
    }

    // MARK: - context

    /// What the tutor knows before it answers.
    ///
    /// Assembled from the two stores rather than hard-coded, which is the whole difference between
    /// a chatbot and a tutor: the lesson, the questions, the weak topics and the streak are real.
    func context() async -> StudyContext {
        let raw = track.rawValue
        let weak = (try? progress?.weakTopics(track: raw)) ?? []
        let notes = (try? progress?.recentNotes(track: raw, limit: 3)) ?? []
        let todos = (try? progress?.openTodos(track: raw)) ?? []
        let trapText: String? = track == .lsat ? await content.trapLibrary() : nil
        return StudyContext(
            track: track,
            day: day,
            mode: mode,
            streakDays: streakDays,
            totalMinutes: totalMinutes,
            weakTopics: weak,
            recentNotes: notes,
            openTodos: todos,
            lessonText: await content.lessonText(track, day: day),
            questionBank: await content.questionBank(track, day: day),
            skillsBlock: await content.skillsBlock(track, day: day),
            errata: await errataText(),
            trapLibrary: trapText ?? ""
        )
    }

    /// The tracked-content note, read from the staged curriculum if it carries one.
    private func errataText() async -> String {
        await content.trackedNote(track, day: day)
    }

    // MARK: - the turn

    func send(_ said: String, apiKey: String) async {
        guard let session, !isThinking else { return }
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        captions.append(Caption(who: .learner, text: trimmed))
        isThinking = true
        lastError = nil
        DiagLog.event("turn.begin", ["chars": trimmed.count, "key": !apiKey.isEmpty])

        do {
            let context = await self.context()
            DiagLog.event("turn.context", [
                "lesson": context.lessonText.count,
                "questions": context.questionBank.count,
                "skills": context.skillsBlock.count,
                "weak": context.weakTopics.count,
            ])
            var spoken = ""
            for try await event in await session.send(trimmed, apiKey: apiKey, context: context) {
                if case let .speech(text) = event { spoken += text }
                await handle(event)
            }
            DiagLog.event("turn.done", ["spokenChars": spoken.count])
            finishTurn()
        } catch {
            DiagLog.event("turn.failed", ["error": "\(error)"])
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captions.append(Caption(who: .system, text: lastError ?? "Something went wrong."))
            isThinking = false
        }
    }

    /// Applies one event: shows it, or records it against progress.
    private func handle(_ event: TutorEvent) async {
        switch event {
        case let .speech(text):
            sentenceBuffer += text
            let sentences = SentenceSplitter.split(sentenceBuffer)
            guard sentences.count > 1 else { return }
            // The tail may still be growing, so it stays back until it is finished.
            let ready = Array(sentences.dropLast())
            sentenceBuffer = sentences.last ?? ""
            for sentence in ready { enqueue(sentence) }

        case let .board(item):
            board = BoardParser.parse(item)
            boardFocus = []
            DiagLog.event("evt.board", ["kind": item.kind, "chars": item.body.count])

        case let .note(text):
            record("evt.note.failed", ["chars": text.count]) {
                try progress?.addNote(text, track: track.rawValue, day: day)
            }
            DiagLog.event("evt.note", ["chars": text.count])

        case let .todo(title, body):
            record("evt.todo.failed", ["title": title]) {
                try progress?.addTodo(title: title, detail: body, track: track.rawValue, day: day)
            }
            DiagLog.event("evt.todo", ["title": title])

        case let .log(topic, result, level):
            if let store = progress, !topic.isEmpty {
                record("evt.log.failed", ["topic": topic]) {
                    try store.recordAnswer(
                        track: track.rawValue,
                        topic: topic,
                        result: result == "miss" ? .miss : .hit
                    )
                }
                DiagLog.event("evt.log", ["topic": topic, "result": result, "level": level])
            }

        case let .layout(board):
            // The tutor widened or narrowed the board. Nothing to record; the shape is re-parsed
            // on the next <board>, and the wide flag rides along in the title the model sets.
            DiagLog.event("evt.layout", ["board": board])

        case let .focus(nodes):
            boardFocus = Set(
                nodes.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )

        case let .covered(section):
            if !section.isEmpty {
                record("evt.covered.failed", ["section": section]) {
                    try progress?.markCovered(track: track.rawValue, day: day, section: section)
                }
                await reloadProgress()
            }

        case .dayDone:
            record("evt.dayDone.failed", ["day": day]) {
                try progress?.setDayStatus(.done, track: track.rawValue, day: day)
            }
            captions.append(Caption(who: .system, text: "Day \(day) done. Back tomorrow."))
            await reloadProgress()
        }
    }

    /// Runs a progress write and says so in the log when it fails.
    ///
    /// These were all bare `try?`, which is what hid the store being broken for so long: every
    /// write threw, every throw was swallowed, and the app looked perfectly healthy while recording
    /// nothing. The log is the only channel on the device — no console, no debugger, no screenshots
    /// — so a swallowed failure has to at least leave a mark there.
    private func record(_ failureEvent: String, _ context: [String: Any], _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            DiagLog.event(failureEvent, context.merging(["error": "\(error)"]) { _, new in new })
        }
    }

    private func enqueue(_ sentence: String) {
        // Newlines included: a model's reply arrives with blank lines in it, and trimming only
        // spaces leaves a "\n" that reads as non-empty and gets spoken as an empty caption.
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let last = captions.last, last.who == .tutor, last.isStreaming {
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

    func interrupt() {
        DiagLog.event("turn.interrupt")
        voice.stop()
        turn?.cancel()
        turn = nil
        sentenceBuffer = ""
        isSpeaking = false
        isThinking = false
        finishTurn()
    }

    func clearBoard() {
        board = nil
        boardFocus = []
    }

    func reset() {
        interrupt()
        captions.removeAll()
        board = nil
        boardFocus = []
        lastError = nil
        Task { await session?.clear() }
    }

    /// Which track and day the UI should offer next.
    func advanceDay() async {
        await select(day: day + 1)
    }
}
#endif
