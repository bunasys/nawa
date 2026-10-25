import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming an HTTP response body, the same way on every platform.
///
/// The streaming clients need the response as soon as its headers arrive
/// and the body bytes as they come. Apple's Foundation has
/// `URLSession.bytes(for:)` for that; Linux Foundation does not, so there
/// `ResponseByteStream` does the same job with a session delegate.
extension URLSession {
    /// Starts `request`; returns once the response headers are in, with
    /// the body as it arrives. Ending the iteration early (or cancelling
    /// the task reading it) cancels the request.
    func streamBytes(for request: URLRequest) async throws -> (HTTPResponseBytes, URLResponse) {
        #if canImport(FoundationNetworking)
        try await ResponseByteStream.open(request, on: self)
        #else
        try await bytes(for: request)
        #endif
    }
}

#if canImport(FoundationNetworking)
typealias HTTPResponseBytes = ResponseByteStream
#else
typealias HTTPResponseBytes = URLSession.AsyncBytes
#endif

/// Reads a whole (error) body as text.
func collectText<Bytes: AsyncSequence>(_ bytes: Bytes) async throws -> String where Bytes.Element == UInt8 {
    var data: [UInt8] = []
    for try await byte in bytes { data.append(byte) }
    return String(decoding: data, as: UTF8.self)
}

/// A response body delivered by a `URLSessionDataDelegate`, as bytes.
///
/// Used on Linux, where `URLSession.bytes(for:)` does not exist; it only
/// needs APIs both Foundations have, so it is built (and tested) on macOS
/// too. Requests run on a `StreamingSession` made from the session they
/// were asked on, so its timeouts and protocol classes apply.
struct ResponseByteStream: AsyncSequence, Sendable {
    typealias Element = UInt8

    private let chunks: AsyncThrowingStream<Data, any Error>

    static func open(_ request: URLRequest, on owner: URLSession) async throws -> (ResponseByteStream, URLResponse) {
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let handler = RequestHandler(chunks: continuation)
        let streaming = StreamingSession.for(owner)
        // The task is made only when the request starts, so a request cancelled
        // before that leaves nothing behind in the long-lived session. Starting
        // and cancelling decide under this lock, so neither can slip in between.
        let phase = Mutex(RequestPhase.waiting)
        @Sendable func cancel() {
            let before = phase.withLock { phase in
                defer { phase = .cancelled }
                return phase
            }
            // Act outside the lock: ending the stream runs `onTermination`,
            // which calls this again (and then finds `.cancelled`).
            switch before {
            case .waiting:
                handler.completed(error: URLError(.cancelled), response: nil)
            case .started(let task):
                streaming.cancel(task)
            case .cancelled:
                break
            }
        }
        // Stopping the reader (or dropping the stream) stops the download.
        continuation.onTermination = { _ in cancel() }

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<URLResponse, any Error>) in
                // Already cancelled: the waiter has its answer, don't start the request.
                guard handler.awaitResponse(waiter) else { return }
                let task = phase.withLock { phase -> URLSessionDataTask? in
                    guard case .waiting = phase else { return nil }
                    let task = streaming.dataTask(with: request, handler: handler)
                    phase = .started(task)
                    return task
                }
                task?.resume()
            }
        } onCancel: {
            cancel()
        }
        return (ResponseByteStream(chunks: chunks), response)
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, any Error>.AsyncIterator
        var buffer = Data()
        var index = Data().startIndex

        mutating func next() async throws -> UInt8? {
            while index == buffer.endIndex {
                guard let chunk = try await chunks.next() else { return nil }
                buffer = chunk
                index = buffer.startIndex
            }
            defer { index = buffer.index(after: index) }
            return buffer[index]
        }
    }

}

/// Where one streamed request is: not started yet, running, or cancelled.
private enum RequestPhase: @unchecked Sendable {
    case waiting
    case started(URLSessionDataTask)
    case cancelled
}

/// Hands one request's response over once, then its body chunks, then the end.
private final class RequestHandler: Sendable {
    private struct ResponseState {
        /// Waiting for the response; nil once it has been answered.
        var waiter: CheckedContinuation<URLResponse, any Error>?
        /// The answer, kept for a waiter that arrives after it (cancellation
        /// can come before `awaitResponse`).
        var outcome: Result<URLResponse, any Error>?
    }

    private let chunks: AsyncThrowingStream<Data, any Error>.Continuation
    private let state = Mutex(ResponseState())

    init(chunks: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.chunks = chunks
    }

    /// Waits for the response. Returns false when the answer is already in
    /// (the waiter has been resumed with it), so the request needn't start.
    func awaitResponse(_ continuation: CheckedContinuation<URLResponse, any Error>) -> Bool {
        let earlier = state.withLock { state -> Result<URLResponse, any Error>? in
            if let outcome = state.outcome { return outcome }
            state.waiter = continuation
            return nil
        }
        guard let earlier else { return true }
        continuation.resume(with: earlier)
        return false
    }

    func received(_ response: URLResponse) {
        answer(.success(response))
    }

    func received(_ data: Data, response: URLResponse?) {
        // In case the response callback was skipped: the body implies it.
        if let response { answer(.success(response)) }
        chunks.yield(data)
    }

    func completed(error: (any Error)?, response: URLResponse?) {
        if let error {
            answer(.failure(error))
            chunks.finish(throwing: error)
            return
        }
        if let response {
            answer(.success(response))
        } else {
            answer(.failure(URLError(.badServerResponse)))
        }
        chunks.finish()
    }

    /// The first answer wins; later ones (a body after a failure) change nothing.
    private func answer(_ result: Result<URLResponse, any Error>) {
        let pending = state.withLock { state -> CheckedContinuation<URLResponse, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            defer { state.waiter = nil }
            return state.waiter
        }
        pending?.resume(with: result)
    }
}

/// One long-lived delegate session per session that streams, shared by all
/// of its requests; callbacks reach each request's handler by task id.
///
/// These sessions are never released. On Linux, releasing a URLSession
/// that has made HTTPS requests aborts the process ("_MultiHandle
/// deallocated with non-zero retain count", swift-corelibs-foundation#5203,
/// fix pending in #5491), so a session per request crashed after the first
/// streamed reply.
///
/// So that callers who make a URLSession per client don't grow the list
/// without bound, a released owner's streaming session serves the next
/// owner with the same settings. Distinct settings still add one each.
/// Sharing is safe because these sessions keep no per-client state: no
/// cookies, credentials or cache (see `stateless(_:)`).
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Every streaming session made so far. Entries are never removed:
    /// removing one would release its session.
    private static let all = Mutex<[StreamingSession]>([])

    /// Only read and written while holding `all`'s lock; nil once the
    /// owner is released, which frees this entry for another owner.
    private weak var owner: URLSession?
    private let configuration: URLSessionConfiguration
    private var session: URLSession!
    private let handlers = Mutex<[Int: RequestHandler]>([:])

    /// The streaming session for requests asked on `owner`: its own, a
    /// released owner's with the same settings, or a new one.
    static func `for`(_ owner: URLSession) -> StreamingSession {
        all.withLock { all in
            if let existing = all.first(where: { $0.owner === owner }) { return existing }
            let configuration = owner.configuration
            let reusable = all.first { $0.owner == nil && sameSettings($0.configuration, configuration) }
            if let reusable {
                reusable.owner = owner
                return reusable
            }
            let created = StreamingSession(owner: owner, configuration: stateless(configuration))
            all.append(created)
            return created
        }
    }

    /// `configuration` without anything that remembers one client for the
    /// next: cookies, stored credentials and cached responses. Streamed calls
    /// are API POSTs authenticated per request, so they need none of it.
    static func stateless(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        return copy
    }

    /// The settings that change how a streamed API call behaves. Cookies,
    /// credentials and caches are left out because `stateless(_:)` removes
    /// them from every streaming session.
    static func sameSettings(_ a: URLSessionConfiguration, _ b: URLSessionConfiguration) -> Bool {
        func protocolNames(_ configuration: URLSessionConfiguration) -> [String] {
            (configuration.protocolClasses ?? []).map { String(reflecting: $0) }
        }
        func headers(_ configuration: URLSessionConfiguration) -> [String] {
            (configuration.httpAdditionalHeaders ?? [:]).map { "\($0.key): \($0.value)" }.sorted()
        }
        let sameTimeouts = a.timeoutIntervalForRequest == b.timeoutIntervalForRequest
            && a.timeoutIntervalForResource == b.timeoutIntervalForResource
        let sameConnections = a.httpMaximumConnectionsPerHost == b.httpMaximumConnectionsPerHost
        let sameProtocols = protocolNames(a) == protocolNames(b)
        let sameHeaders = headers(a) == headers(b)
        let sameProxy = proxy(a) == proxy(b)
        return sameTimeouts && sameConnections && sameProtocols && sameHeaders && sameProxy && samePlatformSettings(a, b)
    }

    private static func proxy(_ configuration: URLSessionConfiguration) -> [String] {
        (configuration.connectionProxyDictionary ?? [:]).map { "\($0.key): \($0.value)" }.sorted()
    }

    /// Settings only Apple's Foundation has.
    private static func samePlatformSettings(_ a: URLSessionConfiguration, _ b: URLSessionConfiguration) -> Bool {
        #if canImport(FoundationNetworking)
        return true
        #else
        return a.waitsForConnectivity == b.waitsForConnectivity
            && a.tlsMinimumSupportedProtocolVersion == b.tlsMinimumSupportedProtocolVersion
            && a.tlsMaximumSupportedProtocolVersion == b.tlsMaximumSupportedProtocolVersion
        #endif
    }

    private init(owner: URLSession, configuration: URLSessionConfiguration) {
        self.owner = owner
        self.configuration = configuration
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Requests started and not finished; for tests.
    var pendingRequests: Int { handlers.withLock { $0.count } }

    /// Cancel a request and end it now. A task cancelled before it started
    /// may never report completion, which would leave its handler (and
    /// whoever waits on it) stuck; a completion that does come later finds
    /// nothing left to do.
    fileprivate func cancel(_ task: URLSessionDataTask) {
        task.cancel()
        let handler = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        handler?.completed(error: URLError(.cancelled), response: nil)
    }

    fileprivate func dataTask(with request: URLRequest, handler: RequestHandler) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        // Registered before the caller resumes the task, so no callback is missed.
        handlers.withLock { $0[task.taskIdentifier] = handler }
        return task
    }

    private func handler(for task: URLSessionTask) -> RequestHandler? {
        handlers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        handler(for: dataTask)?.received(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.received(data, response: dataTask.response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let handler = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        handler?.completed(error: error, response: task.response)
    }
}
