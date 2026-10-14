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
public enum SentenceSplitter {
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "etc", "mr", "mrs", "dr", "st", "no", "approx",
    ]

    /// The trailing word if the text ends in something that only looks like a full stop.
    static func trailingAbbreviation(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(".") else { return nil }
        let lastWord = trimmed.split(separator: " ").last.map(String.init) ?? ""
        let bare = lastWord.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return abbreviations.contains(bare) ? bare : nil
    }

    /// Splits into sentences, holding back any trailing fragment until more arrives.
    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }

            // Closing quotes and brackets belong to the sentence, not after it.
            var lookAhead = current
            while let last = lookAhead.last,
                  last == "\"" || last == "'" || last == ")" || last == "]" {
                lookAhead.removeLast()
            }
            guard lookAhead.last == character else { continue }

            if trailingAbbreviation(lookAhead) != nil { continue }
            sentences.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }

        let remainder = current.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }
}
