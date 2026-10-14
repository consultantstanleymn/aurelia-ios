import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Speaks through a Chatterbox server over HTTP.
///
/// Chatterbox is the chosen voice because it is MIT licensed and the only free model with real
/// paralinguistic control — `[laugh]`, `[chuckle]`, `[sigh]` inline, plus an exaggeration slider.
/// That matters for a tutor, which has to react to a wrong answer differently from a right one.
///
/// It is a 350M-parameter Llama-backbone model, which is the whole design constraint here: it does
/// not fit in an app bundle and does not run at conversational speed on a phone. So it runs on a
/// machine with a GPU and the app streams the finished audio. The cost of that choice is that the
/// voice needs a server, which is why `SystemVoice` exists and why this class is allowed to fail
/// without taking the tutor down with it.
///
/// The server is expected to expose one route:
///
///     POST /v1/speech   {"text": "...", "delivery": {...}}  ->  audio/wav
///
/// `tools/chatterbox-server/README.md` has a reference implementation.
public final class ChatterboxVoice: SpeechEngine, @unchecked Sendable {
    /// Plays the audio a sentence came back as.
    ///
    /// Injected rather than reached for globally because playback needs AVFoundation, and this
    /// module is deliberately Foundation-only so that the test suite runs on Linux. The iOS app
    /// supplies the real one.
    public protocol AudioSink: Sendable {
        func play(_ audio: Data)
        func stop()
    }

    private let endpoint: URL
    private let session: URLSession
    private let sink: any AudioSink
    private let timeout: TimeInterval

    /// Set when the last call failed, so the app can show one clear warning rather than silently
    /// falling back and leaving the reader wondering why the voice changed.
    public private(set) var lastFailure: String?

    public init(
        endpoint: URL,
        sink: any AudioSink,
        session: URLSession = .shared,
        timeout: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.sink = sink
        self.session = session
        self.timeout = timeout
    }

    public func speak(_ text: String, completion: @escaping @Sendable () -> Void) {
        // Chatterbox is too slow for interactive speech on the devices this runs on, so every
        // sentence is synthesized concurrently. Out-of-order audio is the trade: the tutor starts
        // talking immediately instead of after a two-second wait per sentence.
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else {
            completion()
            return
        }

        let turn = TurnCompletion(expected: sentences.count)
        for sentence in sentences {
            request(sentence) { result in
                // A failed sentence still finishes the turn: if one of three comes back 500 the
                // tutor must not hang waiting for a completion that will never arrive.
                guard case let .success(data) = result else {
                    turn.sentenceFinished(completion)
                    return
                }
                self.sink.play(data)
                turn.sentenceFinished(completion)
            }
        }
    }

    public func stop() {
        sink.stop()
    }

    public func shutdown() {
        sink.stop()
    }

    private func request(_ text: String, then: @escaping @Sendable (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        // Generous, because a cold model on CPU can take a while for the first sentence and a
        // short timeout would turn a slow machine into a silent tutor.
        request.timeoutInterval = timeout

        let payload: [String: Any] = [
            "text": text,
            // Emotion is carried in the tags the tutor writes, which the prompt asks for.
            "exaggeration": 0.45,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        session.dataTask(with: request) { data, response, error in
            if let error {
                self.lastFailure = error.localizedDescription
                then(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                self.lastFailure = "HTTP \(http.statusCode)"
                then(.failure(URLError(.badServerResponse)))
                return
            }
            guard let data, !data.isEmpty else {
                then(.failure(URLError(.zeroByteResource)))
                return
            }
            self.lastFailure = nil
            then(.success(data))
        }.resume()
    }
}
