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
    ///
    /// Resolved by looking rather than by assuming, because there are two layouts and the app only
    /// ships one of them.
    ///
    /// The build declares the curricula as a resource of the *app* target, so they are copied into a
    /// nested resource bundle — `Aurelia_Aurelia.bundle/Content` — rather than into the app's own
    /// resources. Reading `Bundle.main.resourceURL/Content` therefore finds nothing at all, and the
    /// symptom is not a crash but a tutor with no material: every track loading zero days, with no
    /// error anywhere. The bundled name follows the package and target names, so it is searched for
    /// rather than hard-coded.
    private var resolvedBase: URL?
    private var didResolveBase = false

    private func baseURL() -> URL? {
        if let rootOverride { return rootOverride }
        if !didResolveBase {
            didResolveBase = true
            resolvedBase = Self.findContentRoot(in: Bundle.main.resourceURL)
        }
        return resolvedBase
    }

    private func root(_ track: Track) -> URL? {
        baseURL()?.appendingPathComponent(track.contentDirectory, isDirectory: true)
    }

    /// Finds the staged curricula in a bundle directory, in either layout.
    ///
    /// Pure enough to test: give it a directory, get back the path or nil. That matters, because the
    /// version this replaced could only be checked by installing on a phone and reading a log, and
    /// that is exactly how it got this far.
    public static func findContentRoot(in container: URL?) -> URL? {
        guard let container else { return nil }
        let manager = FileManager.default

        func directory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        // Straight into the app's own resources.
        let flat = container.appendingPathComponent("Content", isDirectory: true)
        if directory(flat) { return flat }

        // Inside a nested resource bundle. Sorted so the choice is stable when several match.
        let items = (try? manager.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        )) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where item.pathExtension == "bundle" {
            let nested = item.appendingPathComponent("Content", isDirectory: true)
            if directory(nested) { return nested }
        }
        return nil
    }

    public func load() {
        guard !loaded else { return }
        loaded = true
        // Say where it looked, or that it found nothing. A store that silently loads zero days
        // looks exactly like a tutor with nothing to teach.
        DiagLog.event("content.root", [
            "path": baseURL()?.path ?? "not found",
            "override": rootOverride != nil,
        ])
        for track in Track.allCases {
            // Quant ships as weeks.json rather than day pages and days.json, so asking it for day
            // metadata is asking the wrong question — and it answered by logging "noMetadata" on
            // every single launch, which in a log that is the only source of truth reads as a
            // fault rather than as a track that works differently.
            metadata[track] = track.usesWeeklyLayout
                ? nil
                : Self.readMetadata(track, root: root(track))
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
        // Quant is not a set of day pages; its weeks are a JSON file produced by
        // tools/stage-content.sh from a JavaScript literal.
        if track == .quant { return readQuantWeek(day, root: root) }
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

    /// One quant week.
    ///
    /// The checklist's source is a JavaScript object literal with no JavaScript engine available
    /// on the device, so the staging script evaluates it with node and writes plain JSON. The shape
    /// here is tasks grouped by category, which is what the prompt wants as a checklist to work
    /// through rather than as prose to be read aloud.
    private static func readQuantWeek(_ number: Int, root: URL) -> LessonDay? {
        let url = root.appendingPathComponent("weeks.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let wrapper = raw as? [String: Any] else { return nil }
        guard let weeks = wrapper["weeks"] as? [[String: Any]],
              number >= 1, number <= weeks.count else { return nil }
        let row = weeks[number - 1]

        let title = row["title"] as? String ?? "Week \(number)"
        let month = row["month"] as? String ?? ""
        let period = row["period"] as? String ?? ""

        // Group by category so the tutor can say "three of the five are setup" rather than
        // reading a flat list of unrelated links.
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for task in (row["tasks"] as? [[String: Any]] ?? []) {
            let category = (task["category"] as? String ?? "Tasks").trimmingCharacters(in: .whitespaces)
            if grouped[category] == nil {
                grouped[category] = []
                order.append(category)
            }
            var line = (task["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let steps = (task["steps"] as? [String] ?? []).filter { !$0.isEmpty }
            if !steps.isEmpty { line += "\n    - " + steps.joined(separator: "\n    - ") }
            grouped[category]?.append(line)
        }

        let sections = order.map { category in
            LessonSection(
                id: category.lowercased().replacingOccurrences(of: " ", with: "-"),
                title: category,
                text: (grouped[category] ?? []).joined(separator: "\n")
            )
        }

        return LessonDay(
            track: .quant,
            day: number,
            title: title,
            phase: month,
            summary: period.isEmpty ? "" : "\(month) · \(period)",
            sections: sections
        )
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

    /// A correction note for the day, when the curriculum ships one.
    ///
    /// The prompt puts corrections above the lesson and says they override it, which only works if
    /// they are actually delivered. Missing ones are simply empty rather than a placeholder, so an
    /// absent file does not waste tokens telling the tutor there are no errata.
    public func trackedNote(_ track: Track, day number: Int) -> String {
        guard let root = baseURL() else { return "" }
        let file = root
            .appendingPathComponent(track.contentDirectory, isDirectory: true)
            .appendingPathComponent("data/errata.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Quant is not a set of day pages. Its source is a JavaScript object literal, which
    /// `tools/stage-content.sh` evaluates with node at staging time and writes out as a single
    /// `weeks.json`, so it has no `days.json` and no per-day metadata to read. Said here rather
    /// than left to be rediscovered as a missing-file warning on every launch.
    var usesWeeklyLayout: Bool { self == .quant }
}


extension ContentStore {
    /// Where the staged curricula live on disk, used by the test suite.
    public static func stagedRoot(onDisk: String) -> URL? {
        let url = URL(fileURLWithPath: onDisk, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
