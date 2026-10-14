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

        // The session has to be configured AND activated before the input node will report a
        // usable format. Reading outputFormat first returns 0 Hz and 0 channels, and installTap
        // raises an Objective-C exception on an invalid format rather than throwing a Swift
        // error, which is a hard crash with nothing in the log. That ordering is the whole bug.
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord rather than .record: the tutor speaks through AVSpeechSynthesizer, and a
        // record-only category leaves the device unable to play its reply at all. .measurement
        // mode is the right processing for a tutor that must hear a quiet spoken answer.
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .unavailable("Could not open the microphone: \(error.localizedDescription)")
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
        // installTap raises rather than throws on a degenerate format, so it has to be checked
        // before it is called rather than caught.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            request.endAudio()
            self.request = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            state = .unavailable("No usable audio input. Close any other app that may be using the mic.")
            return
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        isTapInstalled = true

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
