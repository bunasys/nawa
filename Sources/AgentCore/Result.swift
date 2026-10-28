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
    /// The part of `outputTokens` spent on reasoning, when the provider
    /// reports it (OpenAI's `completion_tokens_details`); 0 otherwise.
    public var reasoningTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    public static let zero = Usage()

    /// Add another usage record to this one.
    public mutating func accumulate(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        reasoningTokens += other.reasoningTokens
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
    /// The model declined the prompt and no fallback model answered it.
    case refused
}

/// A model declined a request: a safety classifier stopped it, or the model
/// itself refused. Anthropic's classifiers name the policy area (`"cyber"`,
/// `"bio"`, ...); other providers usually say nothing beyond the refusal.
public struct RefusalNotice: Sendable, Hashable, Codable {
    /// The model that declined; nil when the provider didn't say.
    public var declinedBy: String?
    /// The policy area, e.g. `"cyber"`; nil when none applies.
    public var category: String?
    /// The provider's reason, for display only: its wording changes.
    public var explanation: String?
    /// The model answering instead; nil when no model will.
    public var answeredBy: String?

    public init(declinedBy: String? = nil, category: String? = nil, explanation: String? = nil, answeredBy: String? = nil) {
        self.declinedBy = declinedBy
        self.category = category
        self.explanation = explanation
        self.answeredBy = answeredBy
    }
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
    /// The last refusal of this run, whether or not another model then
    /// answered. Clients use it to offer removing the declined prompt.
    public var refusal: RefusalNotice?

    public init(
        kind: AgentResultKind,
        text: String? = nil,
        usage: Usage = .zero,
        numTurns: Int = 0,
        sessionID: String,
        stopReason: StopReason? = nil,
        costEstimate: Double? = nil,
        errorMessage: String? = nil,
        refusal: RefusalNotice? = nil
    ) {
        self.kind = kind
        self.text = text
        self.usage = usage
        self.numTurns = numTurns
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.costEstimate = costEstimate
        self.errorMessage = errorMessage
        self.refusal = refusal
    }

    public var isSuccess: Bool { kind == .success }
}
