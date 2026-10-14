/// An event yielded by the agent loop while it runs a turn.
///
/// This mirrors the message taxonomy of the Claude Agent SDK agent-loop: an
/// `init` system event at the start, an `assistant` event per model response
/// (text and/or tool calls), a `toolResults` event after tools run (played back
/// to the user role on the wire), optional `stream` events for partial output,
/// and a terminal `result` event. ADK's Runner/Event loop concept uses the same
/// yield shape: the loop is an `AsyncSequence` of these events.
public enum AgentEvent: Sendable {
    /// Session lifecycle event, fired once at the start of a run with the
    /// session metadata.
    case initEvent(Session)
    /// One complete model response for a turn, including tool calls if any.
    case assistant(AssistantUpdate)
    /// One tool result, delivered back to the model as a tool-role message.
    case toolResult(ToolCallResult)
    /// The tool results for a turn, delivered back to the model as tool-role messages.
    case toolResults([ToolCallResult])
    /// A partial stream of text/tool-input while a turn is being generated.
    case stream(AgentStreamUpdate)
    /// A human-readable status banner.
    case informational(String)
    /// Marks the end of the agent loop.
    case result(AgentResult)
}

/// Payload for ``AgentEvent/assistant(_:)``.
public struct AssistantUpdate: Sendable {
    /// Plain text produced by the model this turn (may be empty).
    public var text: String
    /// Tool calls the model requested this turn.
    public var toolCalls: [ToolCall]
    /// Usage for this single turn.
    public var usage: Usage
    /// Why the model stopped.
    public var stopReason: StopReason?
    /// Usage across the whole conversation so far, this turn included, so
    /// clients can show spend as it grows rather than only at the end.
    public var sessionUsage: Usage
    /// Estimated cost of the conversation so far, if pricing is configured.
    public var sessionCost: Double?

    public init(
        text: String,
        toolCalls: [ToolCall],
        usage: Usage = .zero,
        stopReason: StopReason? = nil,
        sessionUsage: Usage = .zero,
        sessionCost: Double? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
        self.sessionUsage = sessionUsage
        self.sessionCost = sessionCost
    }

    /// Content blocks for this turn: text first, then tool calls.
    public var content: [ContentBlock] {
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: toolCalls.map { .toolCall($0) })
        return blocks
    }
}

/// Payload for ``AgentEvent/stream(_:)`` — partial output while a turn streams.
public enum AgentStreamUpdate: Sendable {
    case textDelta(String)
    case toolCallStart(ToolCall)
    case toolCallArgumentsDelta(id: String, partialJSON: String)
}
