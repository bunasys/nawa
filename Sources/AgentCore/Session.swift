/// A single conversation between a user and an agent.
///
/// A session owns the `messages` that accumulate across turns (and across
/// multiple `prompt` calls, supporting the resume/continue patterns the agent
/// loop describes), plus the `cwd` the tools operate relative to.
public struct Session: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var messages: [Message]
    /// Working directory the tools in this session operate relative to.
    public var cwd: String

    public init(id: String, messages: [Message] = [], cwd: String = "") {
        self.id = id
        self.messages = messages
        self.cwd = cwd
    }

    /// Append a message and return the updated session.
    public func appending(_ message: Message) -> Session {
        var copy = self
        copy.append(message)
        return copy
    }

    /// Append a message in place.
    public mutating func append(_ message: Message) {
        messages.append(message)
    }

    /// The concatenated text of a user message with the given id, if present.
    public func userMessageText(id: String) -> String? {
        for message in messages where message.role == .user && message.id == id {
            return message.text
        }
        return nil
    }
}
