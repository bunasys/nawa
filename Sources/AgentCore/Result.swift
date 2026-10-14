/// Token accounting for a single model call, and cumulatively for a session.
///
/// Input is split three ways because providers bill them differently: a
/// prompt-cache read costs a fraction of fresh input, a cache write costs a
/// little more. Keeping them apart lets cost estimates and logs show what
/// caching saves.
public struct Usage: Sendable, Hashable, Codable {
    /// Fresh input tokens, not served from or written to the prompt cache.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Input tokens served from the provider's prompt cache.
    public var cacheReadTokens: Int
    /// Input tokens written to the provider's prompt cache on this call.
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static let zero = Usage()

    /// Add another usage record to this one.
    public mutating func accumulate(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }

    /// Everything the model read on this call: the size of the prompt.
    public var promptTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }

    /// Total tokens across input (cached or not) and output.
    public var total: Int { promptTokens + outputTokens }
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
    /// What went wrong, present on `errorDuringExecution` (e.g. the provider's
    /// HTTP status and error body).
    public var errorMessage: String?

    public init(
        kind: AgentResultKind,
        text: String? = nil,
        usage: Usage = .zero,
        numTurns: Int = 0,
        sessionID: String,
        stopReason: StopReason? = nil,
        costEstimate: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.usage = usage
        self.numTurns = numTurns
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.costEstimate = costEstimate
        self.errorMessage = errorMessage
    }

    public var isSuccess: Bool { kind == .success }
}
