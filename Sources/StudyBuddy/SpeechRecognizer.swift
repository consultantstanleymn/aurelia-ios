// Guarded on the platform, not on canImport(Speech). The Speech framework in this SDK ships only
// an arm64e .swiftinterface and no binary swiftmodule for arm64, so canImport answers false even
// though `import Speech` compiles and links perfectly. The first version of this file was gated on
// canImport and the entire recogniser compiled to nothing — which looked exactly like the feature
// not being implemented. Verified with `strings` on the built binary.
#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import Observation
import Speech

/// Turns speech into text, on device.
///
/// This is the half of a voice tutor that was missing: the app could speak but could not listen,
/// which makes it a dictation app with extra steps.
///
/// On-device recognition is requested first and is not a preference. The learner's spoken answers
/// are the thing being assessed, and they are also the most personal thing the app ever handles —
/// a wrong answer read aloud in a quiet room is exactly the kind of thing you do not want leaving
/// the phone. If the device cannot do it locally the recogniser says so rather than quietly
/// falling back to the network.
@MainActor
@Observable
final class SpeechRecognizer {
    enum State: Equatable {
        case idle
        case listening
        case unavailable(String)
    }

    private(set) var state: State = .idle
    /// The live transcript, which is what the composer shows while you talk.
    private(set) var transcript = ""
    /// What the recogniser settled on once you stop. Editable before it is sent, because speech
    /// recognition gets technical terms wrong and a tutor that cannot be corrected is useless.
    private(set) var finalText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    /// installTap and removeTap have to be paired. Removing a tap that was never installed logs an
    /// error and, on some releases, traps — and stop() can be reached from three places.
    private var isTapInstalled = false

    /// True when this device can transcribe without a network round trip.
    var isOnDeviceAvailable: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func toggle() {
        DiagLog.event("mic.toggle", ["state": "\(state)"])
        switch state {
        case .listening: stop()
        case .idle: start()
        case .unavailable: break
        }
    }

    func start() {
        DiagLog.event("mic.start", ["state": "\(state)"])
        guard let recognizer, recognizer.isAvailable else {
            DiagLog.event("mic.recognizerUnavailable", ["nil": recognizer == nil])
            state = .unavailable("Speech recognition is not available on this device.")
            return
        }
        DiagLog.event("mic.recognizerOK", ["onDevice": recognizer.supportsOnDeviceRecognition, "available": recognizer.isAvailable])

        // Two permissions, not one. SFSpeechRecognizer only asks about speech recognition;
        // the microphone is a separate grant, and asking for one does not ask for the other.
        // Without the second one the audio engine fails to start and the recogniser never hears
        // a sample — which looks exactly like a dead microphone button.
        Task { @MainActor in
            let speechOK = await requestSpeechAuthorization()
            guard speechOK else {
                DiagLog.event("mic.speechDenied")
                self.state = .unavailable("Speech recognition was declined. Enable it in Settings.")
                return
            }
            DiagLog.event("mic.speechOK.askingMic")
            let micOK = await requestMicrophoneAuthorization()
            guard micOK else {
                DiagLog.event("mic.micDenied")
                self.state = .unavailable("The microphone was declined. Enable it in Settings.")
                return
            }
            DiagLog.event("mic.bothOK.begin")
            self.beginListening(recognizer: recognizer)
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DiagLog.event("perm.speechStatus", ["raw": status.rawValue])
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    DiagLog.event("perm.micStatus", ["granted": granted])
                    continuation.resume(returning: granted)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DiagLog.event("perm.micStatus", ["granted": granted])
                continuation.resume(returning: granted)
            }
        }
    }

    private func beginListening(recognizer: SFSpeechRecognizer) {
        transcript = ""
        finalText = ""

        // The session has to be configured AND activated before the input node will report a
        // usable format. Reading outputFormat first returns 0 Hz and 0 channels, and installTap
        // raises an Objective-C exception on an invalid format rather than throwing a Swift
        // error, which is a hard crash with nothing in the log. That ordering is the whole bug.
        let session = AVAudioSession.sharedInstance()

        // The session refused to activate with the option set that looked right, and the log said
        // so plainly — "Session activation failed" — after both permissions had already been
        // granted. Rather than pick one configuration and hope, this walks down a ladder and
        // takes the first that actually activates, because which options a session will accept
        // depends on what the system is already doing with audio and is not knowable in advance.
        //
        // .playAndRecord rather than .record: the tutor speaks through AVSpeechSynthesizer, and a
        // record-only category leaves the device unable to play its own reply.
        var attempt = 0
        var activated = false
        var lastError = "unknown"

        let ladder: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playAndRecord, .measurement, [.defaultToSpeaker, .allowBluetooth, .duckOthers]),
            (.playAndRecord, .measurement, [.defaultToSpeaker, .allowBluetooth]),
            (.playAndRecord, .default,     [.defaultToSpeaker]),
            (.playAndRecord, .default,     []),
            (.playAndRecord, .voiceChat,   [.defaultToSpeaker, .allowBluetooth]),
        ]

        for (category, mode, options) in ladder {
            attempt += 1
            // Deactivating first matters: a session left active under a previous category refuses
            // to change category, and the symptom of that is a failed activation with no clue.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            do {
                try session.setCategory(category, mode: mode, options: options)
                DiagLog.event("audio.category", ["try": attempt, "category": "\(category.rawValue)", "mode": "\(mode.rawValue)", "opts": options.rawValue])
                try session.setActive(true)
                DiagLog.event("audio.activated", ["try": attempt, "opts": options.rawValue])
                activated = true
                break
            } catch {
                lastError = error.localizedDescription
                DiagLog.event("audio.attemptFailed", ["try": attempt, "opts": options.rawValue, "error": lastError])
            }
        }

        guard activated else {
            DiagLog.event("audio.allAttemptsFailed", ["tries": attempt, "last": lastError])
            state = .unavailable("Could not open the microphone: \(lastError)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Refuse the network rather than fall back to it. If the device cannot do this locally the
        // recogniser fails and the user is told, which is the correct outcome.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        DiagLog.event("audio.format", ["sampleRate": Int(format.sampleRate), "channels": format.channelCount])
        // installTap raises rather than throws on a degenerate format, so it has to be checked
        // before it is called rather than caught.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            request.endAudio()
            self.request = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            DiagLog.event("audio.degenerateFormat", ["sampleRate": Int(format.sampleRate), "channels": format.channelCount])
            state = .unavailable("No usable audio input. Close any other app that may be using the mic.")
            return
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        isTapInstalled = true
        DiagLog.event("audio.tapInstalled")

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            DiagLog.event("audio.engineStartFailed", ["error": error.localizedDescription])
            state = .unavailable("Could not start the microphone: \(error.localizedDescription)")
            return
        }

        DiagLog.event("audio.engineRunning")
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    DiagLog.event("stt.partial", ["chars": result.bestTranscription.formattedString.count, "final": result.isFinal])
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finalText = self.transcript
                    }
                }
                if let error {
                    DiagLog.event("stt.error", ["error": error.localizedDescription])
                }
                if error != nil || (result?.isFinal ?? false) {
                    DiagLog.event("stt.finished")
                    self.stop()
                }
            }
        }
    }

    /// Stops recording and hands back the transcript.
    ///
    /// The audio engine must be torn down or the next start throws, which is the single most
    /// common way a speech recogniser gets stuck after two uses.
    func stop() {
        DiagLog.event("mic.stop", ["running": engine.isRunning, "tap": isTapInstalled])
        if engine.isRunning { engine.stop() }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        if finalText.isEmpty { finalText = transcript }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        if state == .listening { state = .idle }
    }

    /// Discards whatever was heard, for when someone taps by accident.
    func cancel() {
        stop()
        transcript = ""
        finalText = ""
    }
}
#endif
