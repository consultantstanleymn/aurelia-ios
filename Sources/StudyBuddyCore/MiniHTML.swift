import Foundation

/// The small amount of HTML reading the tutor actually needs.
///
/// Not a general parser and not trying to be one. The curriculum pages come from a known template,
/// so extraction is driven by the class names the Python version keyed on — `doc-section`,
/// `scenario-card`, `scenario-question` — and anything unrecognised is reduced to plain text
/// rather than dropped, so a template change loses formatting and not content.
///
/// A dependency like swift-nia would be more correct and would also mean fetching, vendoring and
/// keeping current something on a Linux box. For a fixed set of generated pages that is a bad
/// trade.
public enum MiniHTML {

    /// One element reduced to text, plus how much HTML it spanned.
    ///
    /// The span is what lets a caller loop over repeated elements and resume in the right place;
    /// without it the next search finds the same element again and the loop never ends.
    struct Element {
        var text: String
        /// Absolute index just past the element, so a caller looping resumes exactly here.
        ///
        /// A character count was the earlier shape and it was wrong: the element's opening tag is
        /// not at the search position, so advancing the search index by the element's length
        /// overshot less than the element actually occupies and the next scan found the same
        /// element again. A four-option question came back with eight options.
        var end: String.Index
    }

    /// The first element carrying `class="<className>"`.
    static func first(in html: String, className: String) -> String? {
        guard let found = scan(html, className: className, from: html.startIndex) else { return nil }
        return found.text
    }

    /// Every element carrying `class="<className>"`, in document order.
    static func all(in html: String, className: String) -> [String] {
        var out: [String] = []
        var index = html.startIndex
        while index < html.endIndex, let found = scan(html, className: className, from: index) {
            out.append(found.text)
            guard found.end > index else { break }
            index = found.end
        }
        return out
    }

    /// The raw inner HTML of every element carrying `class="<className>"`.
    ///
    /// `all(in:className:)` reduces each element to text, which is the wrong shape when the caller
    /// needs to look *inside* — the question cards hold their own classed children, and searching
    /// for those inside already-stripped text finds nothing, silently, which is exactly what
    /// happened: 64 cards found, zero questions parsed.
    static func innerHTMLs(in html: String, className: String) -> [String] {
        var out: [String] = []
        var index = html.startIndex
        while index < html.endIndex, let found = scanInner(html, className: className, from: index) {
            out.append(found.text)
            guard found.end > index else { break }
            index = found.end
        }
        return out
    }

    /// Like `scan` but keeps the element's markup rather than its text.
    private static func scanInner(_ html: String, className: String, from start: String.Index) -> Element? {
        guard let open = html[start...].range(of: "class=\"\(className)\"") else { return nil }
        let afterClass = open.upperBound
        guard let tagOpen = html[html.startIndex ..< open.lowerBound].lastIndex(of: "<"),
              let tagEnd = html[afterClass...].firstIndex(of: ">")
        else { return nil }
        let body = String(html[tagOpen ..< tagEnd])
        let name = body.dropFirst().prefix { $0.isLetter }.lowercased()
        let voids: Set<String> = ["br", "img", "hr", "input", "meta", "link"]
        if voids.contains(name) { return Element(text: "", end: html.index(after: tagEnd)) }

        let contentStart = html.index(after: tagEnd)
        guard let read = read(from: html, startingAt: contentStart) else { return nil }
        let innerEnd = read.end
        // Back up over the closing tag so the slice is the inner HTML only.
        var sliceEnd = innerEnd
        if let closeOpen = html[html.startIndex ..< innerEnd].lastIndex(of: "<") {
            sliceEnd = closeOpen
        }
        let inner = String(html[contentStart ..< max(contentStart, sliceEnd)])
        return Element(text: inner, end: innerEnd)
    }

    /// Scans forward from `start` for the next element with this class and reads it.
    private static func scan(_ html: String, className: String, from start: String.Index) -> Element? {
        var cursor = start
        while cursor < html.endIndex {
            guard let open = html[cursor...].range(of: "class=\"\(className)\"") else { return nil }
            let afterClass = open.upperBound
            // Walk back to the '<' that opens this tag.
            guard let tagOpen = html[html.startIndex ..< open.lowerBound].lastIndex(of: "<"),
                  let tagEnd = html[afterClass...].firstIndex(of: ">")
            else { return nil }
            let body = String(html[tagOpen ..< tagEnd])
            // A void element has no closing tag, so its "text" is just what follows inline.
            let name = body.dropFirst().prefix { $0.isLetter }.lowercased()
            let voids: Set<String> = ["br", "img", "hr", "input", "meta", "link"]
            if voids.contains(name) {
                return Element(text: "", end: html.index(after: tagEnd))
            }
            let contentStart = html.index(after: tagEnd)
            guard let element = read(from: html, startingAt: contentStart) else { return nil }
            return Element(text: element.text, end: element.end)
        }
        return nil
    }

    /// Reads one element's text starting just after its opening tag, tracking nesting.
    private static func read(from html: String, startingAt start: String.Index) -> (text: String, end: String.Index)? {
        var index = start
        var depth = 1
        var text = ""
        while index < html.endIndex {
            guard let tag = html[index...].firstIndex(of: "<") else {
                text += stripTags(String(html[index...]))
                return (decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines), html.endIndex)
            }
            text += stripTags(String(html[index ..< tag]))
            guard let tagEnd = html[tag...].firstIndex(of: ">") else {
                return (decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines), html.endIndex)
            }
            let body = html[html.index(after: tag) ..< tagEnd]
            if body.hasPrefix("/") {
                depth -= 1
                if depth == 0 {
                    let end = html.index(after: tagEnd)
                    return (decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines), end)
                }
            } else if !body.hasSuffix("/") {
                depth += 1
            }
            index = html.index(after: tagEnd)
        }
        return (decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines), html.endIndex)
    }

    /// Every `<section id="...">` with its inner HTML, in order.
    static func sections(in html: String) -> [(id: String, html: String)] {
        var out: [(String, String)] = []
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let open = html[cursor...].range(of: "<section") else { break }
            guard let tagEnd = html[open.upperBound...].firstIndex(of: ">") else { break }
            let header = String(html[open.upperBound ..< tagEnd])
            let bodyStart = html.index(after: tagEnd)
            guard let read = read(from: html, startingAt: bodyStart) else { break }

            var identifier = ""
            if let idOpen = header.range(of: "id=\"") {
                let rest = header[idOpen.upperBound...]
                if let quote = rest.firstIndex(of: "\"") {
                    identifier = String(rest[rest.startIndex ..< quote])
                }
            }
            let innerEnd = html.index(read.end, offsetBy: 0, limitedBy: read.end) ?? read.end
            let inner = String(html[bodyStart ..< innerEnd])
            out.append((identifier, inner))
            cursor = read.end
        }
        return out
    }

    /// The option index from `onclick="revealAnswer('d5q1', 1)"`.
    ///
    /// Read from the raw attribute rather than the rendered text, because the index is displayed
    /// nowhere — only the button's behaviour carries it.
    ///
    /// The id argument is quoted and may itself be parenthesised-looking, so scanning to the first
    /// `)` lands inside the id and finds no comma. The handler is delimited by the closing quote of
    /// the attribute instead, then the index is whatever follows the last comma in that span.
    static func answerIndex(in html: String) -> Int? {
        guard html.contains("scenario-reveal-btn") else { return nil }
        guard let handler = html.range(of: "revealAnswer") else { return nil }
        let rest = html[handler.upperBound...]
        let span = rest.prefix { $0 != "\"" && $0 != ">" }
        guard let comma = span.lastIndex(of: ",") else { return nil }
        let digits = span[span.index(after: comma)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(digits)
    }

    /// Strips a leading "A." / "B2." style marker from an option.
    ///
    /// The pages bake the letter into the option text. It is removed because the prompt block
    /// re-letters every option from A, and leaving the original would produce "A. A. Attach a Deny…".
    static func stripOptionLetter(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        let first = out.first
        guard let first, first.isLetter else { return out }
        var index = out.index(after: out.startIndex)
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

    static func stripTags(_ html: String) -> String {
        var out = ""
        var depth = 0
        for character in html {
            switch character {
            case "<": depth += 1
            case ">": if depth > 0 { depth -= 1 }
            default: if depth == 0 { out.append(character) }
            }
        }
        return out
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&middot;", "·"), ("&rarr;", "→"), ("&larr;", "←"),
            ("&times;", "×"), ("&deg;", "°"), ("&frac12;", "½"),
            ("&bull;", "•"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        while let open = out.range(of: "&#") {
            guard let semi = out[open.upperBound...].firstIndex(of: ";") else { break }
            let body = String(out[open.upperBound ..< semi])
            let value = (body.hasPrefix("x") || body.hasPrefix("X"))
                ? UInt32(body.dropFirst(), radix: 16)
                : UInt32(body, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else {
                out.removeSubrange(open.lowerBound ..< out.index(after: semi))
                continue
            }
            out.replaceSubrange(open.lowerBound ..< out.index(after: semi), with: String(Character(scalar)))
        }
        return out
    }
}
