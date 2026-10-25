import AgentCore

/// What a chat UI needs from the agent, passed in as values so `AgentTUI`
/// never imports `AgentLoop` and can be driven by scripted event streams
/// in tests.
public struct ChatSession: Sendable {
    /// Starts one run; ending the stream early cancels it.
    public var send: @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>
    /// Starts a fresh conversation (`/clear`).
    public var reset: @Sendable () -> Void
    /// Takes the prompt a model declined in the last run out of the
    /// conversation; false when there is none (`AgentLoop.removeDeclinedRequest`).
    public var removeDeclinedRequest: @Sendable () -> Bool
    /// Facts shown once at startup.
    public var header: SessionHeader
    /// Context-fill denominator (the compaction threshold), if any.
    public var contextLimit: Int?
    /// Names of the tools the agent can call (`/tools`).
    public var tools: [String]

    public init(
        header: SessionHeader,
        contextLimit: Int? = nil,
        tools: [String] = [],
        send: @escaping @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>,
        reset: @escaping @Sendable () -> Void = {},
        removeDeclinedRequest: @escaping @Sendable () -> Bool = { false }
    ) {
        self.header = header
        self.contextLimit = contextLimit
        self.tools = tools
        self.send = send
        self.reset = reset
        self.removeDeclinedRequest = removeDeclinedRequest
    }
}
