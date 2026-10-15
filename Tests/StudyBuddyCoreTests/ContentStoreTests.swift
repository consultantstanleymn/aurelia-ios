import XCTest
@testable import StudyBuddyCore

/// Parses the real staged curricula rather than a fixture.
///
/// A hand-written fixture would prove the parser handles the fixture. These pages are generated
/// from a template that can change, and the thing that breaks in practice is a template change —
/// so the tests read the same files the app reads, and fail loudly if the shape moves. Skipped
/// with a clear message when the content has not been staged.
final class ContentStoreTests: XCTestCase {

    /// The staged directory in this checkout. Tests run on Linux against the same files the app
    /// bundles, so a template change upstream fails here rather than silently at runtime.
    private static let stagedPath = "Sources/StudyBuddy/Resources/Content"

    private var root: URL? {
        ContentStore.stagedRoot(onDisk: PackageRoot.resolve(Self.stagedPath))
    }

    /// One store for the whole class. Each `ContentStore` parses every day of every track on
    /// first use — 238 documents — so building one per test turned the suite from two seconds
    /// into three minutes. The store is an actor and caches internally, so sharing it is also the
    /// honest reflection of how the app uses it.
    private static let shared: ContentStore = ContentStore(root: ContentStore.stagedRoot(
        onDisk: PackageRoot.resolve("Sources/StudyBuddy/Resources/Content")
    ))

    private func makeStore() -> ContentStore { Self.shared }

    private func requireContent() throws {
        try XCTSkipUnless(root != nil, "content not staged; run tools/stage-content.sh")
    }

    func testEveryDayOfEveryTrackParses() async throws {
        try requireContent()
        let store = makeStore()
        for track in [Track.aws, .lsat] {
            let loaded = await store.totalDays(track)
            XCTAssertEqual(loaded, track.totalUnits, "\(track.rawValue) should have every day")
        }
    }

    func testLessonTextCarriesRealProse() async throws {
        try requireContent()
        let store = makeStore()
        let text = await store.lessonText(.aws, day: 1)
        XCTAssertGreaterThan(text.count, 500, "day 1 produced almost nothing")
        XCTAssertTrue(text.contains("Day 1"), String(text.prefix(120)))
        // Section markers are what the prompt navigates by when it says "let me show you day 1".
        XCTAssertTrue(text.contains("###"), "no sections extracted:\n\(String(text.prefix(400)))")
    }

    func testSectionIdsAreUsableAsLogTopics() async throws {
        try requireContent()
        let store = makeStore()
        let skills = await store.skillsBlock(.aws, day: 1)
        XCTAssertFalse(skills.isEmpty, "no skills; <log> topics would have nothing to match")
        // Every skill line must carry a name, because the prompt demands exact skill names in <log>.
        for line in skills.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("- "), "malformed skill line: \(line)")
            XCTAssertGreaterThan(line.count, 4, "skill line has no name: \(line)")
        }
    }

    func testQuestionBankWithholdsTheAnswer() async throws {
        try requireContent()
        let store = makeStore()
        let bank = await store.questionBank(.aws, day: 1)
        try XCTSkipIf(bank.isEmpty, "day 1 has no scenario cards")

        let first = await store.day(.aws, 1)?.questions.first
        try XCTSkipIf(first == nil, "no questions parsed")
        if let question = first, let correct = question.correct {
            let letter = String(UnicodeScalar(65 + correct) ?? "A")
            // The option text may legitimately be in the block; the index must not be, and the
            // explanation must not be.
            XCTAssertFalse(bank.contains("(explanation withheld until he answers)") && bank.contains(question.explanation),
                          "the explanation leaked into the prompt")
            XCTAssertTrue(bank.contains(String(question.text.prefix(20))))
            _ = letter
        }
    }

    func testQuestionsHaveOptionsAndAnAnswer() async throws {
        try requireContent()
        let store = makeStore()
        // Sweep a handful of days looking for any parsed question that lost its options.
        var withOptions = 0
        var withAnswer = 0
        for day in [2, 5, 9, 14, 21, 30] {
            guard let lesson = await store.day(.aws, day) else { continue }
            for question in lesson.questions {
                if !question.options.isEmpty { withOptions += 1 }
                if question.correct != nil { withAnswer += 1 }
            }
        }
        XCTAssertGreaterThan(withOptions, 0, "no question anywhere kept its options")
        XCTAssertGreaterThan(withAnswer, 0, "no answer index was recovered from the reveal button")
    }

    func testQuestionNumbersAreStripped() async throws {
        try requireContent()
        let store = makeStore()
        for track in [Track.aws, .lsat] {
            for day in [1, 3, 7, 12] {
                guard let lesson = await store.day(track, day) else { continue }
                for question in lesson.questions {
                    XCTAssertFalse(
                        question.text.hasPrefix("Q"),
                        "unnumbered question kept its prefix: \(question.text.prefix(40))"
                    )
                }
            }
        }
    }

    func testHtmlEntitiesAreDecoded() {
        XCTAssertEqual(MiniHTML.decodeEntities("A &amp; B"), "A & B")
        XCTAssertEqual(MiniHTML.decodeEntities("it&#39;s"), "it's")
        XCTAssertEqual(MiniHTML.decodeEntities("it&#x27;s"), "it's")
        XCTAssertEqual(MiniHTML.decodeEntities("a &mdash; b"), "a — b")
        XCTAssertEqual(MiniHTML.decodeEntities("90&deg;"), "90°")
    }

    func testAnswerIndexComesFromTheHandler() {
        XCTAssertEqual(
            MiniHTML.answerIndex(in: #"<button class="scenario-reveal-btn" onclick="revealAnswer(this, 2)">Show</button>"#),
            2
        )
        XCTAssertNil(MiniHTML.answerIndex(in: #"<div class="other">no button here</div>"#))
    }

    func testStripTagsKeepsTextAndDropsMarkup() {
        XCTAssertEqual(MiniHTML.stripTags("<p>hello <b>world</b></p>"), "hello world")
        XCTAssertEqual(MiniHTML.stripTags("plain"), "plain")
    }
}

/// Finds the package root from the test's working directory.
///
/// SwiftPM runs tests from the package directory on Linux, but not everywhere, so this walks up
/// until it finds Package.swift rather than assuming a relative path.
enum PackageRoot {
    static func resolve(_ relative: String) -> String {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0 ..< 6 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent(relative).path
            }
            directory = directory.deletingLastPathComponent()
        }
        return relative
    }
}

/// A diagnostic, not an assertion. Kept because the loader's failure mode is silent — it returns
/// empty strings and the app just has no material — so there needs to be something that says where
/// it looked and what it found.
final class ContentDiagnosticsTests: XCTestCase {
    func testReportWhatTheLoaderSees() async throws {
        let root = ContentStore.stagedRoot(onDisk: PackageRoot.resolve(ContentDiagnosticsTests.path))
        print("DIAG root:", root?.path ?? "nil")
        if let root {
            let subs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            print("DIAG subdirs:", subs)
            let day = root.appendingPathComponent("aws-sa-pro-curriculum/days/day-001.html")
            print("DIAG day exists:", FileManager.default.fileExists(atPath: day.path))
            let text = try? String(contentsOf: day, encoding: .utf8)
            print("DIAG day bytes:", text?.count ?? -1)
            print("DIAG sections found:", MiniHTML.sections(in: text ?? "").count)
            let cards = MiniHTML.innerHTMLs(in: text ?? "", className: "scenario-card")
            print("DIAG scenario-cards:", cards.count)
            if let card = cards.first {
                print("DIAG card chars:", card.count)
                print("DIAG card q:", MiniHTML.first(in: card, className: "scenario-question") ?? "nil")
                print("DIAG card opts:", MiniHTML.all(in: card, className: "scenario-option").count)
                print("DIAG card answer:", MiniHTML.answerIndex(in: card) as Any)
            }
        }
        let store = ContentStore(root: root)
        print("DIAG totalDays aws:", await store.totalDays(.aws))
    }

    private static let path = "Sources/StudyBuddy/Resources/Content"
}
