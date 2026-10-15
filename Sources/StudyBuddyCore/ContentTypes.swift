import Foundation

/// One day's material: metadata, prose sections and questions.
///
/// Mirrors the dict the Python tutor builds in `content.py`, because the prompt was written against
/// that shape and the model was tuned on seeing it.
public struct LessonDay: Equatable, Sendable {
    public var track: Track
    public var day: Int
    public var title: String
    public var phase: String
    public var week: Int?
    public var summary: String
    public var lab: String
    public var services: [String]
    public var sections: [LessonSection]
    public var questions: [PracticeQuestion]

    public init(
        track: Track,
        day: Int,
        title: String = "",
        phase: String = "",
        week: Int? = nil,
        summary: String = "",
        lab: String = "",
        services: [String] = [],
        sections: [LessonSection] = [],
        questions: [PracticeQuestion] = []
    ) {
        self.track = track
        self.day = day
        self.title = title
        self.phase = phase
        self.week = week
        self.summary = summary
        self.lab = lab
        self.services = services
        self.sections = sections
        self.questions = questions
    }
}

public struct LessonSection: Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

public struct PracticeQuestion: Equatable, Sendable {
    public var text: String
    public var options: [String]
    /// Index of the correct option, recovered from the reveal button's inline handler.
    public var correct: Int?
    public var explanation: String

    public init(text: String, options: [String] = [], correct: Int? = nil, explanation: String = "") {
        self.text = text
        self.options = options
        self.correct = correct
        self.explanation = explanation
    }

    /// The compact form the prompt gets.
    ///
    /// The answer index and the explanation are deliberately withheld. The tutor grades the learner
    /// against `correct`, so a prompt containing it would let the model read the key out instead of
    /// waiting to hear what the learner says.
    public var asPromptBlock: String {
        var out = "Q. \(text)"
        for (index, option) in options.enumerated() {
            let letter = String(UnicodeScalar(65 + index) ?? "A")
            out += "\n  \(letter). \(option)"
        }
        if !explanation.isEmpty { out += "\n  (explanation withheld until he answers)" }
        return out
    }
}

public struct DayMetadata: Equatable, Sendable {
    public var title: String
    public var phase: String
    public var week: Int?
    public var summary: String
    public var lab: String
    public var services: [String]

    public init(
        title: String = "",
        phase: String = "",
        week: Int? = nil,
        summary: String = "",
        lab: String = "",
        services: [String] = []
    ) {
        self.title = title
        self.phase = phase
        self.week = week
        self.summary = summary
        self.lab = lab
        self.services = services
    }
}
