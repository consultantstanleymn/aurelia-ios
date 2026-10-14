import Foundation
// On Darwin, URLSession and friends live in Foundation. On Linux they live in FoundationNetworking,
// which is why this import is conditional: without it the package does not compile on the machine
// the tests run on, which would mean no native test loop.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the tutor's brain lives and which model answers.
///
/// The tutor was written against an OpenAI-compatible `/chat/completions` endpoint, and every
/// provider used since has kept that shape. That is the whole reason swapping brains is two
/// settings rather than a rewrite, and this file is the list of them.
public struct BrainConfiguration: Equatable, Hashable, Sendable {
    /// The chat completions endpoint. No trailing slash.
    public var endpoint: URL
    /// The model id, exactly as the provider names it.
    public var model: String
    /// Provider label, used for the saved-configuration list and for error text.
    public var provider: String

    public init(endpoint: URL, model: String, provider: String) {
        self.endpoint = endpoint
        self.model = model
        self.provider = provider
    }

    // MARK: - presets

    /// OpenCode's Console. Eleven of its models are free, and the gateway is OpenAI-compatible,
    /// so this is the whole reason the tutor can run without a paid API key.
    public static let consoleBase = URL(string: "https://opencode.ai/inference/v1/chat/completions")!

    /// The default. DeepSeek, straight from the phone.
    ///
    /// Not an accident of convenience: the opencode free tier refuses a direct call with
    ///
    ///     403  "OpenCode's free tier can only be used from within OpenCode."
    ///
    /// which is a restriction on the client rather than on the key, and the paid tier on that same
    /// account answers 402 insufficient funds. DeepSeek has neither problem, costs a fraction of a
    /// cent per session, and needs no machine switched on — so the laptop dependency is gone.
    public static let deepSeek = BrainConfiguration(
        endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
        model: "deepseek-chat",
        provider: "DeepSeek"
    )

    /// One line under the provider in Settings, so the choice is not a guess.
    public var note: String {
        switch provider {
        case "DeepSeek": return "Works from the phone with no other machine running."
        default: return "Tried and refused: the Console free tier only answers opencode itself."
        }
    }

    /// Paid fallbacks, for when a free model is throttled or the tutor is being used on exam
    /// night rather than practice.
    public static let paidModels: [BrainConfiguration] = [
        .init(endpoint: consoleBase, model: "glm-5.3-flash", provider: "OpenCode"),
        .init(endpoint: consoleBase, model: "qwen3.8-flash", provider: "OpenCode"),
        .init(endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
              model: "deepseek-chat", provider: "DeepSeek"),
    ]

    // MARK: - derived

    /// The HTTP scheme and host, which is what the Keychain entry is filed under.
    public var host: String { endpoint.host ?? endpoint.absoluteString }
}

/// A message in the tutor's working memory.
public enum ChatRole: String, Sendable {
    case system, user, assistant
}

/// One turn as sent to, and received from, the provider.
public struct ChatMessage: Equatable, Sendable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case role, content }
}

/// Why a turn ended badly. The tutor shows these differently, because "your key was rejected" and
/// "the network dropped" call for different things from the reader.
public enum BrainError: LocalizedError, Equatable {
    case missingKey
    case rejectedKey(status: Int)
    case outOfCredits
    case rateLimited(retryAfter: String?)
    case unreachable(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No API key yet. Add one in Settings."
        case .rejectedKey:
            return "The API key was rejected."
        case .outOfCredits:
            return "The provider's balance is empty."
        case let .rateLimited(retryAfter):
            if let retryAfter { return "Rate limited. Try again in \(retryAfter)s." }
            return "Rate limited. Try again shortly."
        case let .unreachable(detail):
            return "Could not reach the tutor: \(detail)"
        case let .malformedResponse(detail):
            return "The tutor sent something unreadable: \(detail)"
        }
    }
}

/// Streams the tutor's reply.
///
/// Deliberately narrow: it opens a streaming chat completion and yields raw text deltas as they
/// arrive, and knows nothing about tags, prompts or the app. Turning those deltas into speech and
/// side effects is `TutorSession`'s job, which keeps this testable with a stub transport and keeps
/// the wire format in one place.
public protocol BrainTransport: Sendable {
    /// Yields text deltas in order. Throws `BrainError` on anything the UI should explain.
    func stream(
        configuration: BrainConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>
}

/// The real transport, over `URLSession`.
///
/// Free models in particular get rate limited hard and sometimes stall for a long time before
/// the first token, so the timeout is generous and the streaming keeps reading between chunks
/// rather than timing out per read.
/// `@unchecked Sendable` because URLSession is documented as thread-safe; it is the only
/// mutable-looking stored property and it is not mutated after init.
public struct URLSessionBrainTransport: BrainTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(
        configuration: BrainConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: configuration.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 120

                    let body: [String: Any] = [
                        "model": configuration.model,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "stream": true,
                        // A tutor that gives the same opening twice feels broken, and low
                        // temperature keeps it on the curriculum rather than wandering.
                        "temperature": temperature,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Streaming goes through a data delegate rather than `URLSession.bytes(for:)`,
                    // which swift-corelibs-foundation does not implement. The delegate works
                    // identically on both platforms, and real streaming is the point: the tutor
                    // has to start speaking while the model is still writing, not after.
                    let reader = SSEReader()
                    let task = session.dataTask(with: request) {
                        data, response, error in reader.finish(data: data, response: response, error: error)
                    }
                    reader.attach(task: task)

                    var buffer = ""
                    for try await chunk in reader.deltas() {
                        buffer += chunk

                        // Server-sent events: a blank line terminates a record, `data:` carries it.
                        while let split = buffer.range(of: "\n\n") {
                            let record = String(buffer[buffer.startIndex ..< split.lowerBound])
                            buffer = String(buffer[split.upperBound...])
                            if let delta = Self.delta(from: record) {
                                continuation.yield(delta)
                            }
                        }
                    }
                    continuation.finish()
                } catch let error as BrainError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: BrainError.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pulls the text out of one `data:` record. Returns nil for the `[DONE]` sentinel, for
    /// comments, and for the metadata frames some gateways send.
    static func delta(from record: String) -> String? {
        for line in record.split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return nil }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Chat completions puts it under choices[0].delta.content. Some gateways also send
            // a `reasoning` field first; it is thinking, not speech, so it is deliberately dropped.
            guard let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String
            else { continue }
            return content
        }
        return nil
    }

    /// Maps a status code to the thing the reader should be told.
    ///
    /// Takes the code rather than an `HTTPURLResponse` because that type cannot be constructed
    /// in swift-corelibs-foundation, so a version taking the response could not be tested on the
    /// platform the tests run on.
    static func error(statusCode: Int, retryAfter: String? = nil) -> BrainError {
        switch statusCode {
        case 401, 403:
            return .rejectedKey(status: statusCode)
        case 402:
            return .outOfCredits
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .unreachable("HTTP \(statusCode)")
        }
    }
}
