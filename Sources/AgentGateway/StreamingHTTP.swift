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
        try await ResponseByteStream.open(request, configuration: configuration)
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
/// too. Each request gets its own session, with the configuration of the
/// session it was asked on (so its timeouts and protocol classes apply),
/// invalidated as soon as the request is started so it goes away with it.
struct ResponseByteStream: AsyncSequence, Sendable {
    typealias Element = UInt8

    private let chunks: AsyncThrowingStream<Data, any Error>

    static func open(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (ResponseByteStream, URLResponse) {
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let delegate = Delegate(chunks: continuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        session.finishTasksAndInvalidate()
        // Stopping the reader (or dropping the stream) stops the download.
        continuation.onTermination = { _ in task.cancel() }

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<URLResponse, any Error>) in
                delegate.awaitResponse(waiter)
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

    /// Hands the response over once, then the body chunks, then the end.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let chunks: AsyncThrowingStream<Data, any Error>.Continuation
        /// Waiting for the response; nil once it has been answered.
        private let waiter = Mutex<CheckedContinuation<URLResponse, any Error>?>(nil)

        init(chunks: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.chunks = chunks
        }

        func awaitResponse(_ continuation: CheckedContinuation<URLResponse, any Error>) {
            waiter.withLock { $0 = continuation }
        }

        private func answer(_ result: Result<URLResponse, any Error>) {
            let pending = waiter.withLock { waiter in
                defer { waiter = nil }
                return waiter
            }
            pending?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            answer(.success(response))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // In case the response callback was skipped: the body implies it.
            if let response = dataTask.response { answer(.success(response)) }
            chunks.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                answer(.failure(error))
                chunks.finish(throwing: error)
            } else {
                if let response = task.response {
                    answer(.success(response))
                } else {
                    answer(.failure(URLError(.badServerResponse)))
                }
                chunks.finish()
            }
        }
    }
}
