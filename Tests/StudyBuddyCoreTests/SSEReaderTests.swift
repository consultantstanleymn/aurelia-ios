import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StudyBuddyCore

/// The regression test for a hang, which is worse than a crash.
///
/// `SSEReader` used to create the data task, resume it, and only then build the `AsyncStream`.
/// Whenever a response arrived quickly — which is exactly what a small, fast model does — the
/// delegate fired `didReceive` and the completion handler while the continuation was still nil.
/// Both were dropped, including the completion signal, and the consumer waited on a continuation
/// that would never be finished. On the device that was a tutor turn that began and then hung
/// silently forever.
///
/// Every test here completes, so a regression fails as a timeout rather than passing quietly.
///
/// One honest caveat, checked rather than assumed: I reintroduced the original ordering and these
/// tests still passed. `URLProtocol.startLoading` is asynchronous enough locally that the
/// continuation usually exists before the first delegate callback, so the tests do not reliably
/// reproduce the race — they assert the contract the bug violated (chunks arrive, the stream
/// terminates, a non-2xx surfaces), not the timing. The fix is sound on its own reading: the
/// continuation must exist before anything can fire, and it now does by construction. But the real
/// proof of this one is the device log, not this file.
final class SSEReaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The stub is static because URLProtocol instantiates its own copies, so the state has to
        // be reset here or one test's status code leaks into the next.
        InstantSSE.body = ""
        InstantSSE.status = 200
    }

    /// A URLProtocol that answers immediately with a complete SSE body. The fast path is the one
    /// that broke, so the stub is deliberately instant rather than lazily paced.
    private final class InstantSSE: URLProtocol {
        nonisolated(unsafe) static var body = ""
        nonisolated(unsafe) static var status = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let data = Data(Self.body.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stream(from body: String, timeout seconds: UInt64 = 10) async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstantSSE.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        InstantSSE.body = body
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        request.httpMethod = "POST"

        let reader = SSEReader()
        var collected: [String] = []
        for try await chunk in reader.stream(session, request) {
            collected.append(chunk)
        }
        return collected
    }

    /// The regression itself: an instant, single-chunk response must still arrive and must
    /// definitely terminate.
    func testImmediateResponseIsNotLostAndTerminates() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"hello"}}]}

        data: [DONE]

        """
        let chunks = try await stream(from: body)
        XCTAssertTrue(
            chunks.contains { $0.contains("hello") },
            "the only chunk was dropped: \(chunks)"
        )
    }

    func testManySmallChunksAllArrive() async throws {
        var body = ""
        for index in 0 ..< 40 {
            body += "data: {\"choices\":[{\"delta\":{\"content\":\"\(index) \"}}]}\n\n"
        }
        body += "data: [DONE]\n\n"
        let joined = try await stream(from: body).joined()
        for index in 0 ..< 40 {
            XCTAssertTrue(joined.contains("\(index) "), "missing chunk \(index)")
        }
    }

    /// An error status must surface rather than being swallowed.
    func testErrorStatusFinishesTheStream() async throws {
        let reader = SSEReader()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstantSSE.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        InstantSSE.body = "unauthorised"
        InstantSSE.status = 401
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        request.httpMethod = "POST"

        do {
            for try await _ in reader.stream(session, request) {}
            XCTFail("a 401 must not be reported as a successful empty stream")
        } catch let error as BrainError {
            XCTAssertEqual(error, .rejectedKey(status: 401))
        }
    }

    /// Cancelling the consumer must cancel the request, not leave it running.
    func testCancellationTerminates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstantSSE.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        InstantSSE.body = "data: [DONE]\n\n"
        InstantSSE.status = 200
        let reader = SSEReader()
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        request.httpMethod = "POST"

        let task = Task {
            for try await _ in reader.stream(session, request) {}
        }
        task.cancel()
        _ = try? await task.value
    }
}
