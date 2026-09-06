/// Token accounting for a single model call, and cumulatively for a session.
public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let zero = Usage()

    /// Add another usage record to this one.
    public mutating func accumulate(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
    }

    /// Total tokens across input and output.
    public var total: Int { inputTokens + outputTokens }
}

/// How the model finished its final turn.
public enum StopReason: String, Sendable, Hashable, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case refusal
    case cancelled
}

/// Why the whole agent run ended. Mirrors the kernel result subtypes described
/// by the agent-loop documentation (`success`, `error_max_turns`, ...).
public enum AgentResultKind: String, Sendable, Hashable, Codable {
    case success
    case errorMaxTurns = "error_max_turns"
    case errorMaxBudgetUSD = "error_max_budget_usd"
    case errorDuringExecution = "error_during_execution"
}

/// The final outcome of an agent run.
public struct AgentResult: Sendable, Hashable, Codable {
    /// Whether the task succeeded or hit a limit.
    public var kind: AgentResultKind
    /// Final assistant text, only present on `success`.
    public var text: String?
    /// Cumulative token usage across all turns.
    public var usage: Usage
    /// Number of tool-use turns executed.
    public var numTurns: Int
    /// The session this run belonged to, for resumption.
    public var sessionID: String
    /// Why the model stopped on its final turn.
    public var stopReason: StopReason?
    /// Estimated accumulated cost in US dollars, if pricing is configured.
    public var costEstimate: Double?

    public init(
        kind: AgentResultKind,
        text: String? = nil,
        usage: Usage = .zero,
        numTurns: Int = 0,
        sessionID: String,
        stopReason: StopReason? = nil,
        costEstimate: Double? = nil
    ) {
        self.kind = kind
        self.text = text
        self.usage = usage
        self.numTurns = numTurns
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.costEstimate = costEstimate
    }

    public var isSuccess: Bool { kind == .success }
}
