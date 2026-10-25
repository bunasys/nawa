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
        let task = StreamingSession.for(owner).dataTask(with: request, handler: handler)
        // Stopping the reader (or dropping the stream) stops the download.
        continuation.onTermination = { _ in task.cancel() }

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<URLResponse, any Error>) in
                handler.awaitResponse(waiter)
                task.resume()
            }
        } onCancel: {
            task.cancel()
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

/// Hands one request's response over once, then its body chunks, then the end.
private final class RequestHandler: Sendable {
    private let chunks: AsyncThrowingStream<Data, any Error>.Continuation
    /// Waiting for the response; nil once it has been answered.
    private let waiter = Mutex<CheckedContinuation<URLResponse, any Error>?>(nil)

    init(chunks: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.chunks = chunks
    }

    func awaitResponse(_ continuation: CheckedContinuation<URLResponse, any Error>) {
        waiter.withLock { $0 = continuation }
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

    private func answer(_ result: Result<URLResponse, any Error>) {
        let pending = waiter.withLock { waiter in
            defer { waiter = nil }
            return waiter
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
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Every streaming session made so far. Entries are never removed:
    /// removing one would release its session.
    private static let all = Mutex<[StreamingSession]>([])

    /// Only read and written while holding `all`'s lock.
    private weak var owner: URLSession?
    private var session: URLSession!
    private let handlers = Mutex<[Int: RequestHandler]>([:])

    /// The streaming session for requests asked on `owner`, made on first use.
    static func `for`(_ owner: URLSession) -> StreamingSession {
        all.withLock { all in
            // A released owner's entry stays, unused: `owner` is then nil.
            if let existing = all.first(where: { $0.owner === owner }) { return existing }
            let created = StreamingSession(owner: owner)
            all.append(created)
            return created
        }
    }

    private init(owner: URLSession) {
        self.owner = owner
        super.init()
        self.session = URLSession(configuration: owner.configuration, delegate: self, delegateQueue: nil)
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
