import Foundation

// The session journal: a durable record of everything a session did, for
// analysis and for restoring the session later (proposal 0005).
//
// `AgentLoop` writes these records; `AgentJournal` stores them as JSON Lines
// and reads them back. The types live here so both can use them.

/// Where a session's records go.
public protocol SessionJournal: Sendable {
    /// Which program is recording; written into every `session_started`.
    var origin: JournalOrigin { get }
    /// Stores one record. Must not throw or block for long: a journal that
    /// can't write costs the record, never the run.
    func record(_ entry: JournalEntry)
}

/// Which program is recording a journal.
public struct JournalOrigin: Sendable, Hashable {
    /// How Nawa runs: `repl`, `acp`, `serve`, `waku` or `library`.
    public var mode: String
    /// `nawa --version`, when known. Lets a reader tell which encoder built
    /// the requests.
    public var nawaVersion: String?

    public init(mode: String, nawaVersion: String? = nil) {
        self.mode = mode
        self.nawaVersion = nawaVersion
    }
}

/// One record, with the session it belongs to and when it happened.
public struct JournalEntry: Sendable, Hashable {
    public var session: String
    public var at: Date
    public var record: JournalRecord

    public init(session: String, at: Date = Date(), record: JournalRecord) {
        self.session = session
        self.at = at
        self.record = record
    }
}

/// What a journal records. Replaying them in order rebuilds the session:
/// a message with `appendedToContext` joins the end of the context, and a
/// `contextRewrite` replaces the context with its `context` list.
public enum JournalRecord: Sendable, Hashable {
    /// A loop started recording a session.
    case sessionStarted(SessionStart)
    /// A message was created. `appendedToContext` is false for messages
    /// kept only for reference (a helper call's prompt, a declined reply)
    /// and for messages a rewrite puts in place.
    case message(Message, appendedToContext: Bool)
    /// A set of tool definitions sent to the model, recorded once and then
    /// referred to by `id`.
    case tools(id: String, definitions: [ToolDefinition])
    /// `run(prompt:)` began; the prompt is the message with this id.
    case runStarted(promptMessageID: String, model: String?)
    case modelCall(ModelCallRecord)
    case toolRun(ToolRunRecord)
    case contextRewrite(ContextRewrite)
    /// A `steer` message (recorded just before) joined the context.
    case steered(messageID: String)
    /// The `remember` tool saved a note.
    case noteSaved(String)
    /// The model was switched between turns.
    case modelChanged(from: String?, to: String?)
    case refusal(RefusalNotice)
    case runFinished(AgentResult)
}

/// The first record of a session.
public struct SessionStart: Sendable, Hashable {
    public var origin: JournalOrigin
    public var cwd: String
    public var model: String?
    /// The loop's limits and token savers, as the loop describes them.
    public var options: JSON
    /// Set for a sub-agent: the session and `task` call it works for.
    public var parent: JournalParent?
    /// True when a loop restored from this journal picked the session up
    /// again (`AgentLoop(restoring:)`): its messages are already recorded.
    public var resumed: Bool

    public init(origin: JournalOrigin, cwd: String, model: String?, options: JSON, parent: JournalParent? = nil, resumed: Bool = false) {
        self.origin = origin
        self.cwd = cwd
        self.model = model
        self.options = options
        self.parent = parent
        self.resumed = resumed
    }
}

/// What a session needs to go on where it stopped, rebuilt from its journal
/// (`JournalReader.replay`) and handed to `AgentLoop(restoring:)`.
///
/// Not included, because they belong to a run or a process: a pending
/// steer, a declined prompt waiting to be removed, gateway cooldowns.
public struct SessionState: Sendable, Hashable {
    public var sessionID: String
    public var cwd: String
    public var model: String?
    /// The context as the last record left it, system prompt first.
    public var messages: [Message]
    /// Notes saved with the `remember` tool.
    public var notes: [String]
    /// Everything the session spent, its sub-agents included.
    public var usage: Usage
    /// The part of `usage` spent on summaries and sub-agents, which run on
    /// the helper model when one is set.
    public var helperUsage: Usage
    /// Prompt plus reply of the last turn, the signal for compaction; 0
    /// after a rewrite that shrank the context.
    public var contextTokens: Int

    public init(
        sessionID: String,
        cwd: String,
        model: String?,
        messages: [Message],
        notes: [String] = [],
        usage: Usage = .zero,
        helperUsage: Usage = .zero,
        contextTokens: Int = 0
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.messages = messages
        self.notes = notes
        self.usage = usage
        self.helperUsage = helperUsage
        self.contextTokens = contextTokens
    }
}

/// The parent of a sub-agent's session.
public struct JournalParent: Sendable, Hashable {
    public var session: String
    public var callID: String

    public init(session: String, callID: String) {
        self.session = session
        self.callID = callID
    }
}

/// One call to a model: what was sent, what came back, and what it cost.
public struct ModelCallRecord: Sendable, Hashable {
    public enum Purpose: String, Sendable, Hashable {
        /// A turn of the conversation.
        case turn
        /// The summary that compacts older messages.
        case compaction
    }

    public struct Request: Sendable, Hashable {
        /// The messages sent, in order, by id.
        public var messageIDs: [String]
        /// The `tools` record sent, if any.
        public var toolsID: String?
        public var model: String?
        public var provider: String?
        public var maxOutputTokens: Int?
        public var temperature: Double?
        public var streamed: Bool

        public init(messageIDs: [String], toolsID: String?, model: String?, provider: String?, maxOutputTokens: Int?, temperature: Double?, streamed: Bool) {
            self.messageIDs = messageIDs
            self.toolsID = toolsID
            self.model = model
            self.provider = provider
            self.maxOutputTokens = maxOutputTokens
            self.temperature = temperature
            self.streamed = streamed
        }
    }

    public struct Response: Sendable, Hashable {
        /// The reply, recorded as a `message` right after this record.
        public var messageID: String
        public var stopReason: StopReason?
        /// The model that wrote the reply, when the provider said.
        public var model: String?
        /// The configured provider that answered.
        public var provider: String?
        /// The provider the request was meant for, when a fallback answered.
        public var replacedProvider: String?
        /// Models that declined before `model` answered.
        public var declinedBy: [String]

        public init(messageID: String, stopReason: StopReason?, model: String?, provider: String?, replacedProvider: String?, declinedBy: [String]) {
            self.messageID = messageID
            self.stopReason = stopReason
            self.model = model
            self.provider = provider
            self.replacedProvider = replacedProvider
            self.declinedBy = declinedBy
        }
    }

    public var id: String
    public var purpose: Purpose
    public var request: Request
    /// Nil when the call failed (see `error`).
    public var response: Response?
    public var usage: Usage
    /// Estimated, when pricing is configured.
    public var costUSD: Double?
    public var startedAt: Date
    /// Time to the first streamed chunk; nil when the reply didn't stream.
    public var firstChunkMS: Int?
    public var durationMS: Int
    /// Providers that failed before one answered (gateway failover).
    public var failedAttempts: [FailedAttempt]
    public var wire: WireFacts?
    public var error: String?

    public init(
        id: String,
        purpose: Purpose,
        request: Request,
        response: Response?,
        usage: Usage,
        costUSD: Double?,
        startedAt: Date,
        firstChunkMS: Int?,
        durationMS: Int,
        failedAttempts: [FailedAttempt],
        wire: WireFacts?,
        error: String?
    ) {
        self.id = id
        self.purpose = purpose
        self.request = request
        self.response = response
        self.usage = usage
        self.costUSD = costUSD
        self.startedAt = startedAt
        self.firstChunkMS = firstChunkMS
        self.durationMS = durationMS
        self.failedAttempts = failedAttempts
        self.wire = wire
        self.error = error
    }
}

/// A provider that failed before another one answered.
public struct FailedAttempt: Sendable, Hashable {
    public var provider: String
    public var error: String
    public var durationMS: Int

    public init(provider: String, error: String, durationMS: Int) {
        self.provider = provider
        self.error = error
        self.durationMS = durationMS
    }
}

/// Facts about one HTTP exchange with a provider that the messages don't show.
public struct WireFacts: Sendable, Hashable {
    /// Size of the request body: shows how much of a request is JSON
    /// overhead and tool schemas.
    public var requestBytes: Int
    /// The provider's id for the call (`request-id`, `x-request-id`), what
    /// its support asks for.
    public var providerRequestID: String?
    /// Rate-limit headers as sent, e.g. `anthropic-ratelimit-tokens-remaining`.
    public var rateLimitHeaders: [String: String]

    public init(requestBytes: Int, providerRequestID: String? = nil, rateLimitHeaders: [String: String] = [:]) {
        self.requestBytes = requestBytes
        self.providerRequestID = providerRequestID
        self.rateLimitHeaders = rateLimitHeaders
    }
}

/// One tool run. Its arguments and output are in the messages.
public struct ToolRunRecord: Sendable, Hashable {
    public var callID: String
    public var name: String
    public var startedAt: Date
    public var durationMS: Int
    public var outputChars: Int
    public var isError: Bool

    public init(callID: String, name: String, startedAt: Date, durationMS: Int, outputChars: Int, isError: Bool) {
        self.callID = callID
        self.name = name
        self.startedAt = startedAt
        self.durationMS = durationMS
        self.outputChars = outputChars
        self.isError = isError
    }
}

/// Messages in the context were replaced or removed.
public struct ContextRewrite: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case toolResultsCleared = "tool_results_cleared"
        case compaction
        case declinedPromptRemoved = "declined_prompt_removed"
    }

    public var reason: Reason
    public var removed: [String]
    /// New messages, recorded just before this record.
    public var added: [String]
    /// The whole context after the rewrite, in order.
    public var context: [String]
    /// The summary call, for a compaction.
    public var modelCallID: String?

    public init(reason: Reason, removed: [String], added: [String], context: [String], modelCallID: String? = nil) {
        self.reason = reason
        self.removed = removed
        self.added = added
        self.context = context
        self.modelCallID = modelCallID
    }
}

/// Whole milliseconds from `start` to now.
public func millisecondsSince(_ start: Date) -> Int {
    Int((Date().timeIntervalSince(start) * 1000).rounded())
}
