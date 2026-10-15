import Foundation

/// What the composer shows, and how speech gets into it.
///
/// This exists because the recogniser and the composer used to be two things that never met. The
/// recogniser filled `transcript` and `finalText`, the log recorded both, and the composer's text
/// field was bound to a separate `draft` string that nothing ever wrote to. The microphone worked
/// perfectly and the app looked broken, which is the worst kind of bug: every layer reports healthy
/// and the one thing the learner is looking at stays empty.
///
/// The rules live here, in Core and Foundation only, rather than in the view. The view is the part
/// that cannot be tested from this machine — `xtool launch` does not start apps on the phone, so a
/// SwiftUI view is only ever verified by a human looking at a screen. The merge is the part with
/// the decisions in it, and those are worth a test suite.
///
/// One rule runs through all of it: **speech never destroys what the learner typed.** A recogniser
/// that reports nothing, fails, or reports a revision must not leave the composer empty.
public struct ComposerBuffer: Equatable {

    /// What the text field is bound to.
    public private(set) var draft: String

    /// Whatever was in the composer when listening began, kept so the next utterance appends to it
    /// instead of replacing it.
    private var spokenPrefix: String

    /// True once the current draft came from speech rather than from the keyboard. The composer
    /// uses it to decide whether to keep listening to edits.
    public private(set) var lastInputWasSpeech: Bool

    public init(draft: String = "") {
        self.draft = draft
        self.spokenPrefix = ""
        self.lastInputWasSpeech = false
    }

    // MARK: - typing

    /// The learner typed or deleted. The composer is now theirs, so the remembered prefix is
    /// dropped: correcting a transcript must not be undone by the next utterance.
    public mutating func userTyped(_ text: String) {
        draft = text
        spokenPrefix = ""
        lastInputWasSpeech = false
    }

    // MARK: - speech

    /// Listening starts. The current draft becomes the prefix that speech is appended to.
    public mutating func beginListening() {
        spokenPrefix = Self.tidy(draft)
        lastInputWasSpeech = false
    }

    /// A partial result, delivered many times a second.
    ///
    /// Partials revise each other — the recogniser rewrites its own guess as it hears more — so this
    /// replaces the previous speech rather than adding to it, or the composer fills with every
    /// version of the sentence it has ever considered.
    ///
    /// An empty partial is ignored rather than applied. It arrives at the start of every
    /// utterance and again when the recogniser resets, and applying it would blank the composer
    /// mid-sentence.
    public mutating func heard(_ transcript: String) {
        let text = Self.tidy(transcript)
        guard !text.isEmpty else { return }
        draft = Self.join(spokenPrefix, text)
        lastInputWasSpeech = true
    }

    /// The recogniser settled, or the learner stopped it.
    ///
    /// This is the text that gets sent, and it stays in the composer so it can be corrected first —
    /// speech recognition reliably mangles the technical terms a study session is made of, and a
    /// tutor that cannot be corrected is worse than one that asks twice.
    ///
    /// An empty final result leaves the draft alone. This is the case where recognition failed
    /// outright, and clearing the field on failure is how someone loses a sentence they just said.
    public mutating func settled(_ final: String) {
        let text = Self.tidy(final)
        guard !text.isEmpty else { return }
        draft = Self.join(spokenPrefix, text)
        spokenPrefix = Self.tidy(draft)
        lastInputWasSpeech = true
    }

    /// The mic was tapped by accident, so whatever was heard is discarded. Typed text survives,
    /// because it was not the recogniser's to throw away.
    public mutating func discardSpeech() {
        draft = spokenPrefix
        spokenPrefix = ""
        lastInputWasSpeech = false
    }

    /// Sent, or the conversation was reset.
    public mutating func clear() {
        draft = ""
        spokenPrefix = ""
        lastInputWasSpeech = false
    }

    /// Takes the text to send, and empties the composer. Empty is returned as empty, so a send
    /// button wired to this can never post a blank turn.
    public mutating func takeForSending() -> String {
        let text = Self.tidy(draft)
        clear()
        return text
    }

    public var isSendable: Bool {
        !Self.tidy(draft).isEmpty
    }

    // MARK: - text handling

    /// Collapses the whitespace a recogniser sprinkles through its output, and trims the ends.
    ///
    /// Only the speech side is normalised. Typed text is the learner's, and rewriting what someone
    /// typed is its own kind of wrong.
    private static func tidy(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ prefix: String, _ speech: String) -> String {
        if prefix.isEmpty { return speech }
        if speech.isEmpty { return prefix }
        return prefix + " " + speech
    }
}