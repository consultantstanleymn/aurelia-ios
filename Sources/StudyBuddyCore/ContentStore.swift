import Foundation

/// Reads the bundled curricula.
///
/// Without this the tutor has 13 MB of material sitting in its own bundle and an empty lesson in
/// the prompt, which is a hollow app: it can chat but has nothing to teach from. The Python tutor
/// did the same job in `content.py` against cloned repositories; here the material is staged into
/// the bundle by `tools/stage-content.sh` and read from `Bundle.main`.
///
/// Everything is parsed eagerly on first use and cached. The whole set is a few megabytes of text
/// and parsing a day is milliseconds; re-reading per turn would be slower and would change nothing.
public actor ContentStore {

    public static let shared = ContentStore()

    /// Overrides where the curricula are read from.
    ///
    /// The app resolves it from its own bundle, but the test suite runs on Linux against the staged
    /// directory on disk, and Core deliberately has no resources of its own to hang a copy on. One
    /// seam serves both instead of the tests reaching into `Bundle` for something Core cannot see.
    private let rootOverride: URL?

    private var cache: [Track: [Int: LessonDay]] = [:]
    private var metadata: [Track: [Int: DayMetadata]] = [:]
    private var questionBanks: [Track: String] = [:]
    private var trapLibraryText: String?
    private var loaded = false

    public init(root: URL? = nil) { self.rootOverride = root }

    // MARK: - loading

    /// Where the staged curricula live inside the bundle.
    private func root(_ track: Track) -> URL? {
        let base = rootOverride
            ?? Bundle.main.resourceURL?.appendingPathComponent("Content", isDirectory: true)
        return base?.appendingPathComponent(track.contentDirectory, isDirectory: true)
    }

    public func load() {
        guard !loaded else { return }
        loaded = true
        for track in Track.allCases {
            metadata[track] = Self.readMetadata(track, root: root(track))
            var days: [Int: LessonDay] = [:]
            for day in 1 ... track.totalUnits {
                if let lesson = Self.readDay(track, day: day, meta: metadata[track]?[day], root: root(track)) {
                    days[day] = lesson
                }
            }
            cache[track] = days
            DiagLog.event("content.loaded", [
                "track": track.rawValue,
                "days": days.count,
                "meta": metadata[track]?.count ?? 0,
            ])
        }
        trapLibraryText = Self.readTrapLibrary(root: root(.lsat))
    }

    private static func readMetadata(_ track: Track, root: URL?) -> [Int: DayMetadata]? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("data/days.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else {
            DiagLog.event("content.noMetadata", ["track": track.rawValue])
            return nil
        }
        let rows: [[String: Any]]
        if let wrapper = raw as? [String: Any], let inner = wrapper["days"] as? [[String: Any]] {
            rows = inner
        } else if let list = raw as? [[String: Any]] {
            rows = list
        } else {
            return nil
        }

        var out: [Int: DayMetadata] = [:]
        for row in rows {
            guard let number = (row["day"] as? Int) ?? (row["week"] as? Int) else { continue }
            out[number] = DayMetadata(
                title: row["title"] as? String ?? "",
                phase: row["phase"] as? String ?? "",
                week: row["week"] as? Int,
                summary: row["summary"] as? String ?? "",
                lab: row["lab"] as? String ?? "",
                services: row["services"] as? [String] ?? []
            )
        }
        return out
    }

    private static func readDay(_ track: Track, day: Int, meta: DayMetadata?, root: URL?) -> LessonDay? {
        guard let root else { return nil }
        let path = "days/" + String(format: "day-%03d.html", day)
        guard let html = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        else { return nil }

        var sections: [LessonSection] = []
        for section in MiniHTML.sections(in: html) {
            // `quiz` holds the rendered question cards, which are read separately so the tutor
            // never gets the answers pasted into the lesson text.
            if section.id == "quiz" { continue }
            let title = MiniHTML.first(in: section.html, className: "section-heading")
                ?? MiniHTML.first(in: section.html, className: "sub-heading")
                ?? section.id
            let body = MiniHTML.stripTags(section.html)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            sections.append(LessonSection(
                id: section.id,
                title: MiniHTML.decodeEntities(title),
                text: MiniHTML.decodeEntities(body)
            ))
        }

        var questions: [PracticeQuestion] = []
        for card in MiniHTML.innerHTMLs(in: html, className: "scenario-card") {
            guard let text = MiniHTML.first(in: card, className: "scenario-question") else { continue }
            let options = MiniHTML.all(in: card, className: "scenario-option").map(MiniHTML.stripOptionLetter)
            let explanation = MiniHTML.first(in: card, className: "scenario-explanation") ?? ""
            questions.append(PracticeQuestion(
                text: Self.stripQuestionNumber(text),
                options: options,
                correct: MiniHTML.answerIndex(in: card),
                explanation: explanation
            ))
        }

        return LessonDay(
            track: track,
            day: day,
            title: meta?.title ?? "Day \(day)",
            phase: meta?.phase ?? "",
            week: meta?.week,
            summary: meta?.summary ?? "",
            lab: meta?.lab ?? "",
            services: meta?.services ?? [],
            sections: sections,
            questions: questions
        )
    }

    /// "Q3. Which is correct?" -> "Which is correct?"
    ///
    /// The cards number themselves, and the numbers carry no meaning once they are separated from
    /// the question.
    private static func stripQuestionNumber(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        var index = out.startIndex
        // optional leading "Q"
        if index < out.endIndex, out[index] == "Q" || out[index] == "q" {
            index = out.index(after: index)
        }
        var digits = 0
        while index < out.endIndex, out[index].isNumber {
            index = out.index(after: index)
            digits += 1
        }
        guard digits > 0 else { return out }
        while index < out.endIndex, out[index].isWhitespace {
            index = out.index(after: index)
        }
        guard index < out.endIndex, out[index] == "." else { return out }
        index = out.index(after: index)
        while index < out.endIndex, out[index].isWhitespace {
            index = out.index(after: index)
        }
        return String(out[index...])
    }

    private static func readTrapLibrary(root: URL?) -> String? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("data/trap-library.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        guard let array = raw as? [[String: Any]] else { return nil }
        return array.compactMap { row in
            guard let name = row["name"] as? String ?? row["trap"] as? String else { return nil }
            let note = row["note"] as? String ?? row["why"] as? String ?? ""
            let tells = row["tells"] as? [String] ?? []
            var line = "- \(name)"
            if !tells.isEmpty { line += "  (tells: \(tells.joined(separator: "; ")))" }
            if !note.isEmpty { line += "\n  \(note)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - reading

    public func day(_ track: Track, _ number: Int) -> LessonDay? {
        load()
        return cache[track]?[number]
    }

    public func totalDays(_ track: Track) -> Int {
        load()
        return cache[track]?.count ?? 0
    }

    /// The lesson as the prompt wants it, matching the Python `lesson_text` shape section for
    /// section so the model sees the same material it was tuned on.
    public func lessonText(_ track: Track, day number: Int, maxCharacters: Int = 60_000) -> String {
        guard let lesson = day(track, number) else { return "" }
        var parts: [String] = []
        parts.append("# \(track.displayName) - \(track.unitName) \(number): \(lesson.title)")
        if !lesson.phase.isEmpty { parts.append("Phase: \(lesson.phase)") }
        if !lesson.summary.isEmpty { parts.append("Summary: " + lesson.summary) }
        for section in lesson.sections {
            parts.append("\n### [\(section.id)] \(section.title)\n\(section.text)")
        }
        if !lesson.lab.isEmpty { parts.append("\n### Lab\n\(lesson.lab)") }
        let text = parts.joined(separator: "\n")
        return text.count <= maxCharacters ? text : String(text.prefix(maxCharacters))
    }

    /// The question bank block. Answers are withheld deliberately — the tutor grades the learner
    /// and must not be able to read the key out of its own prompt.
    public func questionBank(_ track: Track, day number: Int, limit: Int = 20) -> String {
        guard let lesson = day(track, number) else { return "" }
        let block = lesson.questions.prefix(limit)
            .map { $0.asPromptBlock }
            .joined(separator: "\n\n")
        guard !block.isEmpty else { return "" }
        return "Track: \(track.rawValue) \(number). Each has a correct answer you hold; never reveal it before he answers.\n\n\(block)"
    }

    /// The exact skill names to use in `<log>` tags. The prompt requires these verbatim, and a
    /// mismatched name means the mastery table is written against topics that do not exist.
    public func skillsBlock(_ track: Track, day number: Int) -> String {
        guard let lesson = day(track, number) else { return "" }
        let lines = lesson.sections.map { "- \($0.id) — \($0.title)  (kind: teach)" }
        return lines.joined(separator: "\n")
    }

    public func trapLibrary() -> String? {
        load()
        return trapLibraryText
    }
}

extension Track {
    /// The directory name inside the staged content, which matches the upstream repository names.
    var contentDirectory: String {
        switch self {
        case .aws: return "aws-sa-pro-curriculum"
        case .lsat: return "lsat-170-curriculum"
        case .quant: return "quant-checklist"
        }
    }
}


extension ContentStore {
    /// Where the staged curricula live on disk, used by the test suite.
    public static func stagedRoot(onDisk: String) -> URL? {
        let url = URL(fileURLWithPath: onDisk, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
