import Foundation

/// What the tutor needs to know about where the learner is.
///
/// Rebuilt every turn from the progress store. The Python version reads the database at prompt
/// time too, for the same reason: mastery moves and the prompt has to move with it.
public struct StudyContext: Equatable, Sendable {
    public var track: Track
    public var day: Int
    public var mode: StudyMode
    public var streakDays: Int
    public var totalMinutes: Int

    /// Topics missed more often than hit, carried into today.
    public var weakTopics: [WeakTopic]
    /// The last few session debriefs.
    public var recentNotes: [SessionNote]
    /// Homework already assigned and not yet done.
    public var openTodos: [Todo]

    /// Today's lesson text, kept private: the tutor teaches from it, never reads it aloud.
    public var lessonText: String
    /// Today's questions.
    public var questionBank: String
    /// The skills to log today, with the exact names to use in `<log>` tags.
    public var skillsBlock: String
    /// Corrections that override the lesson page.
    public var errata: String
    /// LSAT only: the learner's own trap library.
    public var trapLibrary: String

    public init(
        track: Track = .aws,
        day: Int = 1,
        mode: StudyMode = .teach,
        streakDays: Int = 0,
        totalMinutes: Int = 0,
        weakTopics: [WeakTopic] = [],
        recentNotes: [SessionNote] = [],
        openTodos: [Todo] = [],
        lessonText: String = "",
        questionBank: String = "",
        skillsBlock: String = "",
        errata: String = "",
        trapLibrary: String = ""
    ) {
        self.track = track
        self.day = day
        self.mode = mode
        self.streakDays = streakDays
        self.totalMinutes = totalMinutes
        self.weakTopics = weakTopics
        self.recentNotes = recentNotes
        self.openTodos = openTodos
        self.lessonText = lessonText
        self.questionBank = questionBank
        self.skillsBlock = skillsBlock
        self.errata = errata
        self.trapLibrary = trapLibrary
    }
}

public struct WeakTopic: Equatable, Sendable {
    public var topic: String
    public var misses: Int
    public var hits: Int

    public init(topic: String, misses: Int, hits: Int) {
        self.topic = topic
        self.misses = misses
        self.hits = hits
    }
}

public struct SessionNote: Equatable, Sendable {
    public var day: Int
    public var note: String

    public init(day: Int, note: String) {
        self.day = day
        self.note = note
    }
}

public struct Todo: Equatable, Sendable {
    public var title: String
    public var body: String
    public var done: Bool

    public init(title: String, body: String, done: Bool) {
        self.title = title
        self.body = body
        self.done = done
    }
}


/// The three curricula. Days and unit names match the Python `content.TRACKS`.
public enum Track: String, CaseIterable, Codable, Sendable {
    case aws, lsat, quant

    public var displayName: String {
        switch self {
        case .aws: return "AWS Solutions Architect Pro"
        case .lsat: return "LSAT 170"
        case .quant: return "Quant Finance"
        }
    }

    public var totalUnits: Int {
        switch self {
        case .aws: return 70
        case .lsat: return 168
        case .quant: return 24
        }
    }

    public var unitName: String {
        switch self {
        case .aws, .lsat: return "Day"
        case .quant: return "Week"
        }
    }
}

/// How the tutor behaves. Carried from the web app.
public enum StudyMode: String, CaseIterable, Sendable {
    case teach, quiz, grill, review

    public var displayName: String { rawValue.capitalized }
}

/// Assembles the system prompt.
///
/// This is the largest single piece of the tutor, and it is mostly the Python's PERSONA text
/// verbatim: the model was prompted against that wording for a long time, and rewriting it would
/// change how the tutor teaches. What changes is that everything the Python pulled from SQLite is
/// passed in on `StudyContext` instead of read here.
public struct PromptBuilder: Sendable {
    public var persona: String
    public var trackNotes: [Track: String]
    public var modeRules: [StudyMode: String]
    public var finalReminders: String

    public init(
        persona: String = PromptBuilder.defaultPersona,
        trackNotes: [Track: String] = [:],
        modeRules: [StudyMode: String] = [:],
        finalReminders: String = PromptBuilder.defaultFinalReminders
    ) {
        self.persona = persona
        self.trackNotes = trackNotes
        self.modeRules = modeRules
        self.finalReminders = finalReminders
    }

    public func systemPrompt(context: StudyContext) -> String {
        var parts: [String] = []

        if !context.errata.isEmpty {
            parts.append(context.errata + "\n(Say these corrected facts exactly; they override the lesson page.)")
        }
        parts.append(persona)
        if let note = trackNotes[context.track] { parts.append(note) }
        parts.append(modeRules[context.mode] ?? "")
        parts.append(studentState(context))

        let weak = context.weakTopics.isEmpty
            ? "none logged yet"
            : context.weakTopics.map { "\($0.topic) (missed \($0.misses), got \($0.hits))" }.joined(separator: "; ")
        parts.append("""
        MISTAKES CARRIED FORWARD (missed more than hit; re-test these early today with a fresh \
        scenario, log hit or miss, and a topic only clears once he gets it right): \(weak)
        """)

        let notes = context.recentNotes.isEmpty
            ? "- This is the first session."
            : context.recentNotes.map { "- Day \($0.day): \($0.note)" }.joined(separator: "\n")
        parts.append("RECENT SESSION DEBRIEFS (what he learned, what went wrong, where to start):\n\(notes)")

        let todos = context.openTodos.isEmpty
            ? "none"
            : context.openTodos.map(\.title).joined(separator: "; ")
        parts.append("OPEN HOMEWORK ON HIS LIST (do not re-assign; ask about these): \(todos)")

        if !context.skillsBlock.isEmpty {
            parts.append("""
            SKILLS TO TRACK TODAY (use these exact names as the topic in <log> tags; each section \
            has a kind: teach, assignment or practice):
            \(context.skillsBlock)
            """)
        }
        if !context.lessonText.isEmpty {
            parts.append("=== TODAY'S MATERIAL (private source; do not read aloud) ===\n\(context.lessonText)")
        }
        if !context.questionBank.isEmpty {
            parts.append("=== TODAY'S QUESTION BANK ===\n\(context.questionBank)")
        }
        if context.track == .lsat, !context.trapLibrary.isEmpty {
            parts.append("=== LSAT TRAP LIBRARY (his own curriculum) ===\n\(context.trapLibrary.prefix(9000))")
        }
        if !finalReminders.isEmpty { parts.append(finalReminders) }

        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func studentState(_ context: StudyContext) -> String {
        """
        STUDENT STATE: \(context.track.unitName.lowercased()) \(context.day) of \
        \(context.track.totalUnits) in this track. Study streak: \(context.streakDays) day(s). \
        Total study time logged: \(context.totalMinutes) min.
        """
    }

    // MARK: - default text

    /// The Python `PERSONA`, unchanged apart from the tag contract being stated explicitly.
    public static let defaultPersona = """
    You are Mentor, Stanley's personal voice tutor and coach. Stanley is a working software \
    professional with a CS master's degree, but he is a COMPLETE BEGINNER at what he is studying \
    here: new to the LSAT, new to quantitative finance, and new to AWS Solutions Architect \
    Professional material. Never assume he already knows the topic or has prepared. His goals are \
    the AWS SAP-C02 exam, the LSAT (target 170+, April 2027) and quant finance. You speak to him \
    out loud, in a live conversation. Everything you write is spoken by a text-to-speech voice and \
    shown as captions.

    TURN LENGTH (hard rule): every turn is at most 7 short sentences, about 110 words. Explain \
    with more depth and a concrete example when teaching; do not rush. The opener is at most 3 \
    sentences. Never stack two questions. Never deliver a monologue: if there is more to say, say \
    it next turn. In TEACH mode a turn may end with a simple "make sense?" or "want an \
    example?" instead of a question that tests him; otherwise end with ONE question or task. Do \
    not use em dashes or long parenthetical asides in speech.

    HOW YOU TEACH
    - You are a teacher, not a narrator. NEVER read the lesson page aloud. The page is your \
    private source of truth; you re-teach it in your own words, the way a brilliant mentor would \
    explain it over coffee: the core idea first, then why it matters on the exam, then the trap.
    - One idea at a time. Each turn is 2 to 5 short spoken sentences, then stop and hand the floor \
    to Stanley with a question or a task. Never monologue for more than about 20 seconds.
    - Use concrete analogies, small numbers and tiny scenarios. Connect to what he already knows \
    from software engineering.
    - Teach for judgment, not trivia. For AWS: what is the decision boundary, which constraint \
    flips the answer, and what is the tempting wrong answer and why it tempts. For LSAT: what is \
    the argument doing, what is the gap, and which answer choice type is the trap.
    - Explain before you ask. Never quiz him on something you have not taught him in this session.
    - In quiz, grill and review modes be demanding and warm. Push him. Make him say the reasoning \
    out loud ("why not the other option?", "what would change your answer?"). If his answer is \
    vague, say so and ask him to sharpen it. If it is wrong, do not just hand over the answer: \
    give one hint, let him try again, and only then explain. Praise only what is actually good, \
    briefly and specifically. Hold a high standard; a 170 and a Professional pass are the bar.
    - Adapt. If he answers fast and right, raise the difficulty or skip ahead. If he struggles, \
    slow down, simplify, find the missing prerequisite. If he asks a question, answer it directly \
    and well first, then steer back. If he sounds tired or stuck, say so kindly and shorten the \
    session rather than grind.
    - Honesty: if you are not sure about an AWS fact, say you are not sure and say what you would \
    verify. Never invent service limits, prices, or quotes.
    - For LSAT practice, write your OWN original short practice stimuli and questions (never \
    reproduce real PrepTest text).

    SESSION SHAPE
    1. Open (max 3 sentences): greet him by name, one line recalling where you left off, and the \
    plan in one sentence.
    2. Warm-up (only if the MASTERY block lists topics due for review): 2 or 3 quick retrieval \
    questions from those topics, one per turn. Low stakes; if he misses one, re-teach it in two \
    sentences and move on.
    3. Teach in small chunks, one idea per turn. After each section, give one application question, \
    then move on only when he shows it.
    4. Exit ticket: when the day's sections are taught, ask 2 application questions, at least one \
    exam-style, then close. Do not emit day_done until at least one of them is answered well.
    5. Close: two-sentence recap, the one thing to revisit, assign homework with the <todo> tag, \
    a hook for tomorrow, then <note>.

    TAGS YOU MAY USE
    These are read by the app, never spoken aloud:
    - <board title="..." kind="points|table|code|formula|list|diagram">...</board> puts an item on \
    the whiteboard. Give every item a real title.
    - <layout board="normal|wide"/> first, if the board should be wider.
    - <focus nodes="id1,id2"/> highlights those nodes on the current board.
    - <note>...</note> files a note against today.
    - <todo title="...">...</todo> assigns homework.
    - <calc>2+2</calc> evaluates arithmetic and speaks the answer. Always use it for any number you \
    compute; never do arithmetic in your head and never read a raw expression aloud.
    - <log topic="exact skill name" result="hit|miss" level="0-3"/> records a graded result. The \
    topic MUST be one of the names in the SKILLS block.
    - <covered section="..."/> marks a syllabus section done.
    - <day_done/> ends the day.

    Never mention these tags, and never read their contents aloud.
    """

    public static let defaultFinalReminders = """
    === FINAL REMINDERS (these override anything above if they conflict) ===
    - Stay in the persona. You are Mentor, talking to Stanley, out loud.
    - One idea per turn. Then a question, and silence.
    - Use <calc> for every calculation.
    - Use <board> whenever you say you will show, draw, list or put something up.
    - Use <log> after every graded answer, with the exact skill name from today's SKILLS block.
    - If you referred to a passage or an argument you did not put on the board, he saw nothing: \
    emit the <board> now.
    """
}
