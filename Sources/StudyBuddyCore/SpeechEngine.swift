import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Says a sentence and reports when it finished.
///
/// The tutor speaks sentence by sentence rather than utterance by utterance, because a reply
/// arrives as a stream: waiting for a full reply before speaking would add seconds of silence to
/// every turn. Splitting on sentences is what makes the tutor feel like it is listening.
///
/// Implementations must be safe to call from any task and must be able to stop mid-sentence —
/// the learner talks over the tutor constantly, and balking is the normal case, not an edge one.
public protocol SpeechEngine: AnyObject, Sendable {
    /// Speaks `text`, calling `completion` on an arbitrary queue when it is done or was cut off.
    func speak(_ text: String, completion: @escaping @Sendable () -> Void)
    /// Stops immediately. Safe to call when nothing is speaking.
    func stop()
    /// Releases resources. Called when the engine is swapped or the app leaves.
    func shutdown()
}

/// Picks the voice and the pace.
///
/// A tutor's prosody carries meaning that text does not: a hint should slow down, a question
/// should lift, and a wrong answer should not be delivered in the same tone as a right one. So
/// the engine is handed a `Delivery`, not a string, and the mapping from mood to prosody lives
/// here rather than being hard-coded into each engine.
public struct Delivery: Equatable, Sendable {
    public enum Mood: Equatable, Sendable {
        /// Neutral teaching.
        case neutral
        /// A hint, after a wrong answer.
        case hint
        /// Praising something that was genuinely right.
        case encouraging
        /// Correcting, without being harsh.
        case correcting
        /// Reading a list or a board aloud.
        case enumerating
        /// Signing off.
        case closing
    }

    public var mood: Mood
    public var rateMultiplier: Double
    public var pitchMultiplier: Double

    public init(mood: Mood, rateMultiplier: Double = 1, pitchMultiplier: Double = 1) {
        self.mood = mood
        self.rateMultiplier = rateMultiplier
        self.pitchMultiplier = pitchMultiplier
    }

    /// The default delivery for ordinary teaching, and the mapping every other mood comes from.
    ///
    /// Numbers are deliberately small. `AVSpeechUtterance` clamps rate to roughly 0.5x–2x and
    /// sounds wrong outside about 0.85x–1.15x, and these same multipliers get handed to a neural
    /// engine where the scale is narrower still.
    public static func forMood(_ mood: Mood) -> Delivery {
        var delivery = Delivery(mood: mood)
        switch mood {
        case .neutral:
            delivery.rateMultiplier = 1.0
        case .hint:
            // Slower and a little lower: gives him time to think without sounding reluctant.
            delivery.rateMultiplier = 0.92
            delivery.pitchMultiplier = 0.98
        case .encouraging:
            // Slightly faster and brighter. Warm, not chirpy.
            delivery.rateMultiplier = 1.04
            delivery.pitchMultiplier = 1.04
        case .correcting:
            // Firm, level. Not slower — that reads as disappointment.
            delivery.rateMultiplier = 0.97
            delivery.pitchMultiplier = 0.96
        case .enumerating:
            delivery.rateMultiplier = 1.02
        case .closing:
            // Warmer and a touch slower, so a session ends rather than stops.
            delivery.rateMultiplier = 0.95
            delivery.pitchMultiplier = 1.02
        }
        return delivery
    }
}

/// Cuts a reply into speakable sentences.
///
/// Ported from the Python `SentenceSplitter`. Two details matter and both were bugs in naive
/// ports: an abbreviation at the end of a line is not a sentence ending, and a sentence must be
/// followed by whitespace before it counts, or "3.5" becomes two sentences.
///
/// The second one was in this file's own documentation for a long time and not in the code. A
/// tutor for AWS and networking says "10.0.0.0/8", "v1.0.44" and "0.023 per GB" as a matter of
/// course, and the old version split every one of them at each full stop — so the CIDR range came
/// out as eight separate spoken fragments, and the version number as four. Nothing about it looks
/// like a crash or a wrong answer. It just sounds like the tutor cannot read numbers aloud, which
/// is precisely the thing it is there to teach.
public enum SentenceSplitter {
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "etc", "mr", "mrs", "dr", "st", "no", "approx",
        // Not in the Python list, and not needed there: its splitter ran over text it had already
        // been handed whole. This one runs over a stream, so the difference between "e.g." and the
        // end of a sentence is often only the next character.
        "u.s", "u.k", "jr", "sr", "fig", "eq", "cf", "al", "inc", "ltd",
    ]

    /// Characters that can close a sentence and belong to it: a quote or bracket after the full
    /// stop is part of what was just said.
    private static let closers: Set<Character> = [
        "\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}",
    ]

    /// The trailing word if the text ends in something that only looks like a full stop.
    static func trailingAbbreviation(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the closers first: a line ending `Mr."` is still an abbreviation, and the quote is
        // not part of the word.
        while let last = trimmed.last, closers.contains(last) || last == "." {
            trimmed.removeLast()
        }
        guard let lastWord = trimmed.split(separator: " ").last else { return nil }
        // Stripped from both ends, so `"e.g."` and `U.S.` reduce to something in the list.
        let bare = lastWord
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'()[]{}\u{201D}\u{2019}"))
        guard !bare.isEmpty else { return nil }
        return abbreviations.contains(bare) ? bare : nil
    }

    /// Splits into sentences, holding back any trailing fragment until more arrives.
    ///
    /// The caller keeps the last element and prepends it to the next chunk, so a sentence already
    /// returned must never be revised. Everything here is written to preserve that: text is only
    /// ever released once a terminator is followed by whitespace, or the text ends.
    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard character == "." || character == "!" || character == "?" else { continue }

            // A closing quote or bracket belongs to the sentence it ends. Looked ahead rather than
            // appended: taking it into the sentence and then deciding the full stop was an
            // abbreviation would leave the quote to be read a second time on the next pass, and
            // the caption would end in two of them.
            var afterClosers = index
            while afterClosers < characters.count, closers.contains(characters[afterClosers]) {
                afterClosers += 1
            }

            // Whitespace after the terminator, or the end of the text. Anything else means the full
            // stop belongs to the word in front of it: an abbreviation, a decimal, a version, a
            // range. This single rule is what keeps 10.0.0.0/8 in one piece.
            if afterClosers < characters.count, !characters[afterClosers].isWhitespace {
                continue
            }

            if trailingAbbreviation(current) != nil { continue }

            current.append(contentsOf: characters[index..<afterClosers])
            let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            current = ""
            index = afterClosers
        }

        // Newlines included in the trim, and empty sentences dropped. A model reply arrives with
        // blank lines in it, and a "\n" that survives here is spoken aloud as a caption.
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }
}
