import Foundation

/// One thing the tutor did, as the model wrote it.
///
/// The tutor's replies are not plain prose. They interleave speech with hidden tags that drive the
/// app: put something on the whiteboard, file a note, set homework, run a calculation out loud,
/// record a graded result, mark the day done, move the board's focus, or change its layout.
///
/// Speech is what the voice reads and the captions show. Everything else is side effect and is
/// never spoken. The parser's whole job is telling those two apart on a stream that arrives in
/// arbitrary chunks, so that a tag split across two network reads is still one tag.
public enum TutorEvent: Equatable, Sendable {
    /// Something to say and show. The only case the voice ever sees.
    case speech(String)
    /// Put an item on the whiteboard.
    case board(BoardItem)
    /// A filed note for today.
    case note(String)
    /// Homework, given at the end of a session.
    case todo(title: String, body: String)
    /// A graded result the tutor is recording.
    case log(topic: String, result: String, level: Int)
    /// Move the board's focus to a comma-separated list of node ids.
    case focus(nodes: String)
    /// Change the board layout, `normal` or `wide`.
    case layout(board: String)
    /// A syllabus section the tutor has now covered.
    case covered(section: String)
    /// The day is finished.
    case dayDone
}

/// A whiteboard item. `kind` decides the shape; `body` is the text or the mermaid source.
public struct BoardItem: Equatable, Sendable {
    public var title: String
    public var kind: String
    public var body: String

    public init(title: String, kind: String, body: String) {
        self.title = title
        self.kind = kind
        self.body = body
    }
}

/// Splits the tutor's token stream into speech and side-effect events.
///
/// Ported from `TagParser` in the Python server, and the two have to agree exactly: the prompt
/// tells the model which tags exist, so a disagreement between parser and prompt silently drops
/// whiteboard content or, worse, reads a tag aloud.
///
/// Two details are load-bearing and easy to get wrong. First, a `<` that might still turn out to
/// be the start of a tag is held back rather than spoken — otherwise a tag split across two
/// network reads gets half of `<bo` read out loud. Second, `\n` arrives as a literal backslash-n
/// and has to be unescaped, because the model writes it inside an XML-ish attribute stream where
/// a real newline would terminate the tag.
public struct TagParser {
    /// Tags with a closing `</name>`.
    static let paired = ["board", "note", "todo", "calc"]
    /// Self-closing tags, written `<name/>`.
    static let selfClosing = ["log", "day_done", "focus", "layout", "covered"]

    private var buffer = ""

    public init() {}

    /// Feed the next chunk of the stream. Returns everything that became decidable.
    public mutating func feed(_ chunk: String) -> [TutorEvent] {
        buffer += chunk
        return drain(final: false)
    }

    /// Flush at end of stream: anything still held back is now speech, not a tag.
    public mutating func flush() -> [TutorEvent] {
        let events = drain(final: true)
        if !buffer.isEmpty {
            let rest = buffer
            buffer = ""
            return events + [.speech(rest)]
        }
        return events
    }

    /// Joins runs of adjacent speech into single events, leaving every side effect where it was.
    ///
    /// The parser emits speech in whatever pieces the tags forced it to: `5 < 7` comes out as
    /// three events because the `<` is not a tag and has to be handed to the speech path on its
    /// own. That is right for the parser and wrong for a caption, which would otherwise show
    /// `5 `, `<`, ` 7` as three separate lines. Everything downstream — the caption view and the
    /// sentence splitter — wants speech merged and side effects not.
    public static func mergingSpeech(_ events: [TutorEvent]) -> [TutorEvent] {
        var out: [TutorEvent] = []
        for event in events {
            if case let .speech(text) = event, case let .speech(last)? = out.last {
                out[out.count - 1] = .speech(last + text)
            } else {
                out.append(event)
            }
        }
        return out
    }

    // MARK: - private

    private mutating func drain(final: Bool) -> [TutorEvent] {
        var out: [TutorEvent] = []
        while !buffer.isEmpty {
            guard let open = buffer.firstIndex(of: "<") else {
                out.append(.speech(buffer))
                buffer = ""
                return out
            }

            if open != buffer.startIndex {
                out.append(.speech(String(buffer[buffer.startIndex ..< open])))
                buffer = String(buffer[open...])
            }

            guard let match = matchTag(in: buffer) else {
                // Could still be the front of a tag name, such as `<boa`. Hold it back rather than
                // speak a bracket the model never meant. The length guard stops an unclosed `<`
                // from swallowing the rest of a reply if the model just wrote a stray one.
                let partial = String(buffer.dropFirst())
                if !final,
                   partial.count < 12,
                   Self.paired.contains(where: { $0.hasPrefix(partial) })
                       || Self.selfClosing.contains(where: { $0.hasPrefix(partial) }) {
                    return out
                }
                out.append(.speech("<"))
                buffer = String(buffer.dropFirst())
                continue
            }

            let name = match.name
            if Self.selfClosing.contains(name) {
                guard let close = buffer.range(of: "/>") else {
                    if final { buffer = "" }
                    return out
                }
                let tag = String(buffer[buffer.startIndex ..< close.upperBound])
                buffer = String(buffer[close.upperBound...])
                let attributes = Self.attributes(in: tag)
                switch name {
                case "log":
                    let level = Int(attributes["level"] ?? "0") ?? 0
                    out.append(.log(
                        topic: attributes["topic"] ?? "",
                        result: attributes["result"] ?? "hit",
                        level: level
                    ))
                case "focus":
                    out.append(.focus(nodes: attributes["nodes"] ?? ""))
                case "layout":
                    out.append(.layout(board: attributes["board"] ?? "normal"))
                case "covered":
                    out.append(.covered(section: attributes["section"] ?? ""))
                default:
                    out.append(.dayDone)
                }
            } else {
                let closing = "</\(name)>"
                guard let close = buffer.range(of: closing) else {
                    if final { buffer = "" }
                    return out
                }
                let inner = String(buffer[buffer.startIndex ..< close.lowerBound])
                buffer = String(buffer[close.upperBound...])

                let head: String
                let body: String
                if let split = inner.firstIndex(of: ">") {
                    head = String(inner[inner.startIndex ..< split])
                    body = String(inner[inner.index(after: split)...])
                } else {
                    head = ""
                    body = inner
                }

                let attributes = Self.attributes(in: head)
                let text = body
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                switch name {
                case "board":
                    out.append(.board(BoardItem(
                        title: attributes["title"] ?? "",
                        kind: attributes["kind"] ?? "points",
                        body: text
                    )))
                case "todo":
                    out.append(.todo(title: attributes["title"] ?? "", body: text))
                case "calc":
                    out.append(.speech(SafeCalc.speak(text)))
                default:
                    out.append(.note(text))
                }
            }
        }
        return out
    }

    private struct TagMatch {
        let name: String
        let length: Int
    }

    /// Matches `<name` followed by a word boundary, mirroring the `\\b` in the Python regex.
    private func matchTag(in text: String) -> TagMatch? {
        guard text.hasPrefix("<") else { return nil }
        for name in Self.paired + Self.selfClosing {
            guard text.count > name.count + 1 else { continue }
            let start = text.index(text.startIndex, offsetBy: 1)
            let end = text.index(start, offsetBy: name.count)
            guard text[start ..< end] == name else { continue }
            let after = text[end]
            // \b: a word character must not follow the name, so `<boardish>` is not `<board>`.
            guard !after.isLetter, !after.isNumber, after != "_" else { continue }
            return TagMatch(name: name, length: name.count + 1)
        }
        return nil
    }

    /// Pulls `key="value"` pairs out of a tag head. Models occasionally emit unquoted or
    /// single-quoted values, so both are accepted rather than dropping the tag.
    ///
    /// The key is the run of word characters immediately before the `=`, not everything since the
    /// last one. Scanning from the start instead swallows the tag name — in `<log topic="RTO"`
    /// the first key would come out as `<log topic` and the attribute would be lost.
    static func attributes(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }

            var keyStart = equals
            while keyStart > text.startIndex {
                let previous = text.index(before: keyStart)
                let character = text[previous]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                keyStart = previous
            }
            let key = String(text[keyStart ..< equals])
            if key.isEmpty { index = text.index(after: equals); continue }

            var cursor = text.index(after: equals)
            guard cursor < text.endIndex else { break }
            let quote = text[cursor]
            guard quote == "\"" || quote == "'" else {
                index = equals
                continue
            }
            cursor = text.index(after: cursor)
            guard let valueEnd = text[cursor...].firstIndex(of: quote) else { break }
            out[key] = String(text[cursor ..< valueEnd])
            index = text.index(after: valueEnd)
        }
        return out
    }
}
