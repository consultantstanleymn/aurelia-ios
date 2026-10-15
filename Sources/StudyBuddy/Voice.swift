// The iOS-only half of the package. On Linux this file compiles to nothing, which is what
// lets `swift test` run the core suite natively here. xtool builds it for real.
#if canImport(AVFoundation)
import AVFoundation
import Foundation
import StudyBuddyCore

/// The on-device voice. Free, instant, and works with the network off.
///
/// Apple's best tier is `AVSpeechSynthesisVoiceQualityPremium` — a neural voice, a clear step up
/// from the `Default` tier most apps settle for. There is no per-word emotion control in
/// AVSpeechSynthesizer, only `rate` and `pitchMultiplier`, which is why `Delivery` exists: the
/// mood mapping in Core does as much as this API allows.
public final class SystemVoice: NSObject, SpeechEngine, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@Sendable () -> Void)?
    private let lock = NSLock()

    /// The highest-quality voice for the language, preferring a voice that is actually downloaded.
    /// A voice that is not installed still "works" — it silently falls back to a robotic one, so
    /// asking for quality is the only way to notice.
    public static func bestVoice(for language: String = "en-US") -> AVSpeechSynthesisVoice? {
        DiagLog.event("voice.bestVoice", ["lang": language])
        // speechVoices() returns only voices installed on the device, so a premium entry here is
        // one that will really be used rather than silently falling back to something robotic.
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        let best = installed.max { $0.quality.rawValue < $1.quality.rawValue }
        DiagLog.event("voice.resolved", ["count": installed.count, "name": best?.name ?? "none", "quality": Int(best?.quality.rawValue ?? -1)])
        return best
    }

    /// The premium voices this device actually has, so Settings can list them by name.
    public static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.quality.rawValue != $1.quality.rawValue {
                return $0.quality.rawValue > $1.quality.rawValue
            }
            return $0.name < $1.name
        }
    }

    public func speak(_ text: String, completion: @escaping @Sendable () -> Void) {
        DiagLog.event("voice.speak", ["chars": text.count, "engine": "system"])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion()
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        // iOS clamps rate outside roughly 0.5x-2x, and the default already sits a little slow for
        // a tutor answering questions, so this nudges up rather than replacing the default.
        utterance.rate = 0.56 * AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.02

        lock.lock()
        self.completion = completion
        lock.unlock()

        // A learner talking over the tutor is the normal case, so anything already queued is
        // dropped rather than allowed to finish.
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    public func stop() {
        DiagLog.event("voice.stop")
        synthesizer.stopSpeaking(at: .immediate)
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        // Whoever was waiting for the sentence has to be released or the turn never ends.
        pending?()
    }

    public func shutdown() {
        stop()
    }
}

extension SystemVoice: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?()
    }
}

/// Plays the WAV audio a Chatterbox server returns.
///
/// AVAudioPlayer rather than AVSpeechSynthesizer because the audio already exists by the time it
/// arrives; this only has to put it on the speaker. Queued, because Chatterbox sentences are
/// synthesized concurrently and can come back out of order — playing them as they land is the
/// trade that buys the tutor its low latency.
public final class AudioQueueSink: ChatterboxVoice.AudioSink, @unchecked Sendable {
    private var queue: [AVAudioPlayer] = []
    private var index = 0
    private let lock = NSLock()

    public init() {
        configureSession()
    }

    private func configureSession() {
        // Deliberately not configuring the category here. The recogniser needs .playAndRecord
        // while it listens, and a voice engine that reconfigures the shared AVAudioSession on init
        // will pull the category out from under it — which is exactly the "Session activation
        // failed" this app was hitting. .playAndRecord with .defaultToSpeaker plays the tutor
        // fine, so there is nothing to gain by fighting over it.
        DiagLog.event("voice.sessionLeftToRecogniser")
    }

    public func play(_ audio: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        player.prepareToPlay()
        queue.append(player)
        // Play everything not yet started, in arrival order. Already-playing players are left
        // alone: interrupting one mid-word to start another sounds worse than a short wait.
        while index < queue.count {
            queue[index].play()
            index += 1
        }
        // Drop what has already finished so a long session does not grow without bound.
        if index > 8 {
            queue.removeFirst(index - 4)
            index = 4
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        queue.forEach { $0.stop() }
        queue.removeAll()
        index = 0
    }
}
#endif
