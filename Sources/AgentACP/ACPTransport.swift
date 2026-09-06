import AgentCore
import AgentJSONRPC
import Foundation

/// Where an outbound ACP message should be delivered.
public enum ACPRoute: Sendable, Hashable {
    /// Connection-scoped stream (responses to `session/new`, `session/load`, ...).
    case connection
    /// Session-scoped stream (notifications + `session/prompt` responses).
    case session(String)
}

/// A sink for outbound ACP JSON-RPC messages.
///
/// Implementations route messages to the appropriate stream (SSE) or writer
/// (WebSocket). The protocol is the single seam between the agent logic and
/// the transport, keeping the two composable and independently testable.
public protocol ACPMessageSink: Sendable {
    func send(_ message: JSONRPCMessage, route: ACPRoute) async
}

/// A buffered, single-consumer outbound stream of JSON-RPC messages.
///
/// Messages published before a consumer attaches are buffered (unbounded) and
/// delivered when the consumer arrives — this is what makes the streamable-HTTP
/// POST→GET correlation reliable: a POST response can be published before the
/// client opens the matching GET stream.
public final class ACPEventStream: @unchecked Sendable {
    private let continuation: AsyncStream<JSONRPCMessage>.Continuation
    public let stream: AsyncStream<JSONRPCMessage>

    public init() {
        let (stream, continuation) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
    }

    public func publish(_ message: JSONRPCMessage) {
        continuation.yield(message)
    }

    public func finish() {
        continuation.finish()
    }
}
