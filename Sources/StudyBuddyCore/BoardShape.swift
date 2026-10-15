import Foundation

/// Turns a whiteboard item into the shapes the view can draw.
///
/// The tutor emits `<board kind="...">` with a plain-text body, and the kinds mean genuinely
/// different things, so they are separated here rather than in the view. Parsing is pure so it can
/// be tested on Linux against every kind at once, which matters because the alternative is finding
/// out that `table` renders as a wall of text on the device.
public enum BoardShape: Equatable, Sendable {
    /// A titled list, one item per line.
    case points(title: String, items: [String])
    /// Pipe- or tab-delimited rows with a header.
    case table(title: String, header: [String], rows: [[String]])
    /// Monospaced, for shell or config.
    case code(title: String, lines: [String])
    /// Key on the left, value on the right.
    case formula(title: String, pairs: [Pair])
    /// A mermaid diagram. The one kind the app cannot draw natively.
    case diagram(title: String, source: String)

    public var title: String {
        switch self {
        case let .points(title, _), let .table(title, _, _), let .code(title, _),
             let .formula(title, _), let .diagram(title, _):
            return title
        }
    }
}

public extension BoardShape {
    /// One key/value row of a formula board.
    struct Pair: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

/// Reads the kinds the prompt asks for: points, table, code, formula, list, diagram.
///
/// `list` is accepted as an alias of `points` because the prompt names both and the model uses
/// them interchangeably.
public enum BoardParser {

    public static func parse(_ item: BoardItem) -> BoardShape {
        let title = item.title.isEmpty ? item.kind.capitalized : item.title
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)

        switch item.kind.lowercased() {
        case "table":
            let table = parseTable(body)
            return .table(title: title, header: table.header, rows: table.rows)
        case "code":
            return .code(title: title, lines: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        case "formula", "formulas":
            return .formula(title: title, pairs: parsePairs(body))
        case "diagram", "mermaid", "flowchart":
            return .diagram(title: title, source: body)
        case "list":
            return .points(title: title, items: parsePoints(body))
        case "points", "", "text":
            // The model often writes points as "Title: x" lines without bullets. Treating any
            // non-empty line as an item is the forgiving reading and matches what it means.
            return .points(title: title, items: parsePoints(body))
        default:
            return .points(title: title, items: parsePoints(body))
        }
    }

    static func parsePoints(_ body: String) -> [String] {
        body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in
                var out = line
                for bullet in ["- ", "* ", "• ", "· "] where out.hasPrefix(bullet) {
                    out = String(out.dropFirst(bullet.count))
                    break
                }
                // "A. text", "B) text" and "1. text" lose their marker. A two-digit value such as
                // "15. Reserved" keeps it: a marker is a letter or a *single* digit, and stripping
                // any numeric prefix quietly deletes real content.
                let markerEnd = out.firstIndex { !$0.isLetter && !$0.isNumber }
                let prefix = markerEnd.map { String(out[out.startIndex ..< $0]) } ?? out
                let looksLikeMarker = prefix.count <= 2
                    && (prefix.allSatisfy(\.isLetter) || prefix.count == 1)
                if looksLikeMarker, let markerEnd,
                   out[markerEnd] == "." || out[markerEnd] == ")" {
                    var after = out.index(after: markerEnd)
                    while after < out.endIndex, out[after] == " " { after = out.index(after: after) }
                    if after < out.endIndex { out = String(out[after...]) }
                }
                return out.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Rows split on `|` or tabs, with a single space-separated row allowed as a fallback.
    ///
    /// The first row is treated as a header when every cell is non-numeric, which is the only
    /// signal available without a real HTML table. Guessing wrong is cheap: a header that was
    /// really data just renders one row bold.
    static func parseTable(_ body: String) -> (header: [String], rows: [[String]]) {
        var rows: [[String]] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "|" }) else { continue }
            let cells = trimmed.contains("|")
                ? trimmed.split(separator: "|", omittingEmptySubsequences: true).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                : trimmed.split(separator: "\t").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            if cells.count == 1 {
                let parts: [String] = trimmed
                    .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    .map(String.init)
                rows.append(parts.count > 1 ? parts : [trimmed])
            } else {
                rows.append(cells.map { String($0) })
            }
        }
        guard let first = rows.first else { return ([], []) }
        let looksLikeHeader = first.allSatisfy { cell in
            Double(cell.replacingOccurrences(of: "%", with: "")) == nil
        }
        return looksLikeHeader ? (first, Array(rows.dropFirst())) : ([], rows)
    }

    /// "key: value" or "key = value", one per line.
    static func parsePairs(_ body: String) -> [BoardShape.Pair] {
        body.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[trimmed.startIndex ..< colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : BoardShape.Pair(key: key, value: value)
            }
            if let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[trimmed.startIndex ..< equals].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : BoardShape.Pair(key: key, value: value)
            }
            return nil
        }
    }
}
