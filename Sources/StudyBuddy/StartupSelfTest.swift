#if os(iOS) || os(macOS)
import Foundation
import StudyBuddyCore

/// Proves the two things that cannot be proven from here, once, on the device.
///
/// Both of the app's external dependencies live off the machine: DeepSeek over the network and
/// the microphone through the audio hardware. Neither can be exercised from the build machine —
/// `xtool launch` does not start apps on this phone — so the only place they can be verified is on
/// the device itself, and the only observable is the file log.
///
/// So the app checks itself. Once per install it runs the audio path as far as it can without
/// anyone speaking — request permissions, activate the session, read the format, install the tap,
/// start the engine — and sends one short turn to DeepSeek. Both outcomes land in the log.
///
/// It is deliberately not a permanent feature. It runs once, records that it has run, and never
/// does it again, because an app that silently talks to a paid API on every launch is a bill
/// nobody asked for. The turn is four words.
@MainActor
enum StartupSelfTest {

    private static let doneKey = "aurelia.selftest.ran"

    static func runIfNeeded(
        ears: SpeechRecognizer,
        tutor: TutorController,
        apiKey: String
    ) {
        let done = UserDefaults.standard.bool(forKey: doneKey)
        if done {
            DiagLog.event("selftest.skipped", ["why": "already ran this install"])
            return
        }
        UserDefaults.standard.set(true, forKey: doneKey)

        Task {
            DiagLog.event("selftest.begin", ["key": !apiKey.isEmpty])

            // 1. The audio path, as far as it goes without a voice.
            DiagLog.event("selftest.audio.begin")
            ears.start()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            DiagLog.event("selftest.audio.result", [
                "state": "\(ears.state)",
                "transcriptChars": ears.transcript.count,
            ])
            ears.stop()

            // 2. One real turn against DeepSeek, from the phone, over wifi.
            guard !apiKey.isEmpty else {
                DiagLog.event("selftest.brain.skipped", ["why": "no key"])
                DiagLog.event("selftest.end")
                return
            }
            DiagLog.event("selftest.brain.begin")
            // TutorController.send dispatches and records the turn itself, and already logs
            // turn.begin / turn.done / turn.failed. All this needs to do is let it run and then
            // capture whatever ended up in the caption list.
            await tutor.send("Reply with the single word: connected", apiKey: apiKey)
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            let said = tutor.captions
                .filter { $0.who == .tutor }
                .map(\.text)
                .joined(separator: " ")
            DiagLog.event("selftest.brain.result", [
                "chars": said.count,
                "reply": String(said.prefix(80)),
                "failed": tutor.lastError ?? "no",
            ])
            DiagLog.event("selftest.end")
        }
    }
}
#endif
