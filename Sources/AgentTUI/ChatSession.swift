import AgentCore

/// What a chat UI needs from the agent, passed in as values so `AgentTUI`
/// never imports `AgentLoop` and can be driven by scripted event streams
/// in tests.
public struct ChatSession: Sendable {
    /// Starts one run; ending the stream early cancels it.
    public var send: @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>
    /// Starts a fresh conversation (`/clear`).
    public var reset: @Sendable () -> Void
    /// Facts shown once at startup.
    public var header: SessionHeader
    /// Context-fill denominator (the compaction threshold), if any.
    public var contextLimit: Int?

    public init(
        header: SessionHeader,
        contextLimit: Int? = nil,
        send: @escaping @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>,
        reset: @escaping @Sendable () -> Void = {}
    ) {
        self.header = header
        self.contextLimit = contextLimit
        self.send = send
        self.reset = reset
    }
}
