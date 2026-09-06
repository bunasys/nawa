import Foundation

/// Who a message comes from in a conversation.
public enum Role: String, Sendable, Hashable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A single item inside a message.
///
/// Content blocks keep the agent model provider-neutral: the same conversation
/// can be rendered to the OpenAI chat-completions wire format by the gateway,
/// to the Anthropic format, or to an ACP `session/update`.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)

    /// A request from the assistant to run a tool.
    case toolCall(ToolCall)

    /// The result of a tool run, delivered back to the model.
    case toolResult(ToolCallResult)

    /// The tool call id, if this block is a tool result.
    public var toolCallID: String? {
        if case .toolResult(let r) = self { return r.callID }
        return nil
    }

    /// The trailing text, concatenated across any `.text` blocks that this value
    /// covers — used when a caller wants a single flat string.
    public var text: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

/// A single message in the conversation history.
public struct Message: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var role: Role
    public var content: [ContentBlock]

    public init(id: String = UUID().uuidString, role: Role, content: [ContentBlock]) {
        self.id = id
        self.role = role
        self.content = content
    }

    /// Convenience initializer for a plain text message.
    public init(id: String = UUID().uuidString, role: Role, text: String) {
        self.init(id: id, role: role, content: [.text(text)])
    }

    /// Concatenated text content of this message (excludes tool calls/results).
    public var text: String {
        content.compactMap(\.text).joined()
    }

    /// The tool calls requested by this assistant message, if any.
    public var toolCalls: [ToolCall] {
        content.compactMap { if case .toolCall(let c) = $0 { return c }; return nil }
    }
}

/// A request from the model to run a tool.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    /// Unique identifier, echoed back in the tool result so results correlate to calls.
    public var id: String
    /// The name of the tool to run.
    public var name: String
    /// The tool's input parameters as a JSON object.
    public var arguments: JSON

    public init(id: String, name: String, arguments: JSON = .object([:])) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Convenience grouping of a tool call with its eventual result.
    public static func result(_ call: ToolCall, content: String, isError: Bool = false) -> ContentBlock {
        .toolResult(ToolCallResult(callID: call.id, name: call.name, content: content, isError: isError))
    }
}

/// The outcome of running a tool, correlated to the originating ``ToolCall`` by call id.
public struct ToolCallResult: Sendable, Hashable, Codable {
    /// The `ToolCall.id` this result answers.
    public var callID: String
    /// The name of the tool that ran.
    public var name: String
    /// The tool output.
    public var content: String
    /// Whether the tool run failed.
    public var isError: Bool

    public init(callID: String, name: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }

    /// A message carrying this result back to the model (role `.tool`).
    public var asMessage: Message {
        Message(role: .tool, content: [.toolResult(self)])
    }
}
