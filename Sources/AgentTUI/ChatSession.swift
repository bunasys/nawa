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
    /// The conversation so far, for a resumed session (`repl --resume`):
    /// its last prompts are shown under the header.
    public var history: [Message]

    public init(
        header: SessionHeader,
        contextLimit: Int? = nil,
        tools: [String] = [],
        history: [Message] = [],
        send: @escaping @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>,
        reset: @escaping @Sendable () -> Void = {},
        removeDeclinedRequest: @escaping @Sendable () -> Bool = { false }
    ) {
        self.header = header
        self.contextLimit = contextLimit
        self.tools = tools
        self.history = history
        self.send = send
        self.reset = reset
        self.removeDeclinedRequest = removeDeclinedRequest
    }
}
