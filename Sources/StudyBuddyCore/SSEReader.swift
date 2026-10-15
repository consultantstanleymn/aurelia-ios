import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a streaming HTTP response as an `AsyncStream` of text chunks.
///
/// `URLSession.bytes(for:)` would be the obvious tool and it is unavailable in
/// swift-corelibs-foundation, which is the toolchain the tests run on. The delegate API is
/// implemented on both platforms and behaves the same, so the package compiles for a Linux test
/// loop and streams properly on the phone.
///
/// The response is not checked here. `URLSession` reports a non-2xx through the delegate's
/// completion handler rather than as an error, so a 401 arrives as data plus a status code, and
/// turning that into "your key was rejected" is the transport's job, not this type's.
final class SSEReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var task: URLSessionDataTask?
    private var completed = false

    /// Starts the request and returns the stream of text chunks.
    ///
    /// The continuation is created and stored BEFORE the task is resumed, and that order is the
    /// whole point. Doing it the other way round — create the task, resume it, then build the
    /// stream — loses the race whenever the response arrives quickly: the delegate fires
    /// `didReceive` and the completion handler while `continuation` is still nil, both are
    /// dropped, and the consumer then waits on a continuation that is never finished. On the
    /// phone that showed up as a turn that started and then hung forever with no error, which is
    /// what the self-test's `turn.begin` with no `turn.done` was.
    ///
    /// Owning the request inside the stream's builder is what makes the ordering impossible to get
    /// wrong from the call site.
    func stream(_ session: URLSession, _ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let task = session.dataTask(with: request) { [weak self] data, response, error in
                self?.finish(data: data, response: response, error: error)
            }

            lock.lock()
            self.task = task
            lock.unlock()

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                task.cancel()
            }

            task.resume()
        }
    }

    /// Called by the transport once it has the status code.
    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        continuation?.finish(throwing: error)
    }

    func finish(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        let continuation = self.continuation
        let alreadyDone = completed
        self.completed = true
        lock.unlock()
        guard !alreadyDone, let continuation else { return }

        if let error {
            continuation.finish(throwing: error)
            return
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            continuation.finish(throwing: URLSessionBrainTransport.error(
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            ))
            return
        }
        // The tail of a stream that did not end on a blank line still has to be parsed.
        if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
            continuation.yield(text)
        }
        continuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(text)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = self.continuation
        let alreadyDone = completed
        lock.unlock()
        if let error, !alreadyDone {
            continuation?.finish(throwing: error)
        }
    }
}
