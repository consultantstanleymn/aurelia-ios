import Foundation

/// Evaluates the arithmetic the tutor writes inside `<calc>` tags and returns it as spoken text.
///
/// The tutor does this itself because the model is bad at arithmetic and worse at saying numbers
/// aloud. Everything here is a closed evaluator over a fixed set of operators and functions: no
/// names, no attribute access, no subscripting, nothing that could reach outside the expression.
/// The Python original walks the AST with an explicit allow-list; this evaluates the same grammar
/// directly, so there is no eval of any kind.
public enum SafeCalc {
    public static func speak(_ expression: String) -> String {
        var parser = Parser(normalise(expression))
        guard let value = parser.parseSum(), parser.atEnd else { return "that number" }
        return spoken(value)
    }

    /// `^` is how the model writes power and `%` is how it writes percent; both are rewritten
    /// before parsing rather than taught to the parser.
    static func normalise(_ expression: String) -> String {
        expression
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^", with: "**")
            .replacingOccurrences(of: "%", with: "/100")
    }

    /// Formats a result the way it should be heard, matching the Python branches exactly:
    /// negatives become a sign plus the magnitude, anything whole is spoken with thousands
    /// separators, a non-whole number at or above a thousand keeps one decimal and its separators,
    /// and anything smaller falls back to four significant figures.
    static func spoken(_ value: Double) -> String {
        if value < 0 { return "negative " + spoken(-value) }
        if value.rounded() == value {
            return grouped(value, fractionDigits: 0)
        }
        if abs(value) >= 1000 {
            return grouped(value, fractionDigits: 1)
        }
        return String(format: "%.4g", value)
    }

    /// Thousands separators and a fixed number of decimals, done by hand.
    ///
    /// `NumberFormatter` was the obvious choice and it is wrong here: on Linux it ignores
    /// `maximumFractionDigits` and rendered 1500.25 as "1,500.25", two decimals past what the
    /// original asks for. Rounding half-to-even matters too — that is what turns 1500.25 into
    /// 1500.2 rather than 1500.3 — so this scales, rounds, and reassembles by hand.
    private static func grouped(_ value: Double, fractionDigits: Int) -> String {
        let scale = pow(10.0, Double(fractionDigits))
        let scaled = (value * scale).rounded(.toNearestOrEven)

        var whole = Int(abs(scaled) / scale)
        let fraction = Int(abs(scaled).truncatingRemainder(dividingBy: scale))

        var digits = String(whole)
        if digits.count > 3 {
            var grouped = ""
            for (offset, character) in digits.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 { grouped.append(",") }
                grouped.append(character)
            }
            digits = String(grouped.reversed())
        }

        guard fractionDigits > 0 else { return digits }
        return digits + "." + String(
            format: "%0\(fractionDigits)d",
            fraction
        )
    }

    // MARK: - recursive descent

    private struct Parser {
        private let characters: [Character]
        private var position = 0

        init(_ expression: String) {
            characters = Array(expression)
        }

        var atEnd: Bool {
            var index = position
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            return index >= characters.count
        }

        mutating func parseSum() -> Double? {
            guard var left = parseProduct() else { return nil }
            while true {
                skipSpace()
                if consume("+") {
                    guard let right = parseProduct() else { return nil }
                    left += right
                } else if consume("-") {
                    guard let right = parseProduct() else { return nil }
                    left -= right
                } else {
                    return left
                }
            }
        }

        private mutating func parseProduct() -> Double? {
            guard var left = parsePower() else { return nil }
            while true {
                skipSpace()
                if consume("*") {
                    // `**` is power, handled in parsePower; a single `*` is multiply.
                    if position < characters.count, characters[position] == "*" { position += 1; continue }
                    guard let right = parsePower() else { return nil }
                    left *= right
                } else if consume("/") {
                    guard let right = parsePower() else { return nil }
                    guard right != 0 else { return nil }
                    left /= right
                } else {
                    return left
                }
            }
        }

        /// Right-associative power. This peeks rather than consumes, because `**` and `*` share a
        /// first character: consuming the `*` and then finding no second one would swallow the
        /// multiplication operator and turn `1250*4` into a parse error.
        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            let mark = position
            skipSpace()
            guard position + 1 < characters.count,
                  characters[position] == "*",
                  characters[position + 1] == "*" else {
                position = mark
                return base
            }
            position += 2
            guard let exponent = parsePower() else { return nil }
            return pow(base, exponent)
        }

        private mutating func parseUnary() -> Double? {
            skipSpace()
            if consume("-") { return parseUnary().map { -$0 } }
            if consume("+") { return parseUnary() }
            return parseAtom()
        }

        private mutating func parseAtom() -> Double? {
            skipSpace()
            guard position < characters.count else { return nil }

            let character = characters[position]

            if character.isNumber || character == "." {
                var literal = ""
                while position < characters.count,
                      characters[position].isNumber || characters[position] == "." {
                    literal.append(characters[position])
                    position += 1
                }
                return Double(literal)
            }

            if character.isLetter {
                var name = ""
                while position < characters.count, characters[position].isLetter {
                    name.append(characters[position])
                    position += 1
                }
                guard position < characters.count, characters[position] == "(" else { return nil }
                position += 1
                var arguments: [Double] = []
                skipSpace()
                if position < characters.count, characters[position] == ")" {
                    position += 1
                } else {
                    while true {
                        guard let argument = parseSum() else { return nil }
                        arguments.append(argument)
                        skipSpace()
                        if consume(",") { continue }
                        guard consume(")") else { return nil }
                        break
                    }
                }
                return apply(name, arguments)
            }

            if consume("(") {
                let value = parseSum()
                guard consume(")") else { return nil }
                return value
            }

            return nil
        }

        /// The allow-list. Nothing outside this table is evaluable, which is the entire point.
        private func apply(_ name: String, _ arguments: [Double]) -> Double? {
            switch name {
            case "ln", "log": guard arguments.count == 1 else { return nil }; return log(arguments[0])
            case "exp": guard arguments.count == 1 else { return nil }; return exp(arguments[0])
            case "sqrt": guard arguments.count == 1 else { return nil }; return sqrt(arguments[0])
            case "round": guard arguments.count == 1 else { return nil }; return arguments[0].rounded()
            case "abs": guard arguments.count == 1 else { return nil }; return abs(arguments[0])
            default: return nil
            }
        }

        private mutating func skipSpace() {
            while position < characters.count, characters[position].isWhitespace { position += 1 }
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipSpace()
            guard position < characters.count, characters[position] == character else { return false }
            position += 1
            return true
        }
    }
}
