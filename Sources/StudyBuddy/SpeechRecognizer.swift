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

    /// True when this device can transcribe without a network round trip.
    var isOnDeviceAvailable: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func toggle() {
        switch state {
        case .listening: stop()
        case .idle: start()
        case .unavailable: break
        }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Speech recognition is not available on this device.")
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.state = .unavailable("Speech recognition was declined in Settings.")
                    return
                }
                self.beginListening(recognizer: recognizer)
            }
        }
    }

    private func beginListening(recognizer: SFSpeechRecognizer) {
        transcript = ""
        finalText = ""

        let session = AVAudioSession.sharedInstance()
        // .record with .duckOthers and .allowBluetooth: measurement is the whole point of the app,
        // and a study session is often next to a laptop speaker.
        try? session.setCategory(
            .record,
            mode: .measurement,
            options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Refuse the network rather than fall back to it. If the device cannot do this locally the
        // recogniser simply fails and the user is told, which is the correct outcome.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            state = .unavailable("Could not start the microphone: \(error.localizedDescription)")
            return
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finalText = self.transcript
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
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
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
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
