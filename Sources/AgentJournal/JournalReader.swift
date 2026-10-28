import AgentCore
import Foundation

/// Reads a journal back.
public enum JournalReader {
    /// Every record in the file. A missing file reads as empty.
    public static func read(_ url: URL) -> JournalContents {
        guard let data = FileManager.default.contents(atPath: url.path) else { return JournalContents(lines: []) }
        return parse(data)
    }

    /// Every record in `data`. A line that doesn't decode (cut off by a
    /// crash, or written by a newer Nawa) is skipped and counted.
    public static func parse(_ data: Data) -> JournalContents {
        var lines: [JournalLine] = []
        var skipped = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let decoded = try? JournalFormat.decode(Data(line)) {
                lines.append(decoded)
            } else {
                skipped += 1
            }
        }
        return JournalContents(lines: lines, skippedLines: skipped)
    }
}

/// A journal's records, with lookups for analysing them.
public struct JournalContents: Sendable {
    public var lines: [JournalLine]
    /// Lines that didn't decode.
    public var skippedLines: Int

    public init(lines: [JournalLine], skippedLines: Int = 0) {
        self.lines = lines
        self.skippedLines = skippedLines
    }

    public var entries: [JournalEntry] { lines.map(\.entry) }

    /// Every message recorded, by id.
    public var messagesByID: [String: Message] {
        var messages: [String: Message] = [:]
        for case .message(let message, _) in entries.map(\.record) {
            messages[message.id] = message
        }
        return messages
    }

    /// Every tool set recorded, by id.
    public var toolsByID: [String: [ToolDefinition]] {
        var tools: [String: [ToolDefinition]] = [:]
        for case .tools(let id, let definitions) in entries.map(\.record) {
            tools[id] = definitions
        }
        return tools
    }

    /// Every model call, in order.
    public var modelCalls: [ModelCallRecord] {
        entries.compactMap { entry in
            if case .modelCall(let call) = entry.record { return call }
            return nil
        }
    }

    /// A session's context as the journal leaves it: a message recorded
    /// with `appendedToContext` joins the end, a rewrite sets the order.
    /// This is what restoring a session starts from.
    public func context(ofSession session: String) -> [Message] {
        let messages = messagesByID
        var context: [Message] = []
        for entry in entries where entry.session == session {
            switch entry.record {
            case .message(let message, let appendedToContext) where appendedToContext:
                context.append(message)
            case .contextRewrite(let rewrite):
                context = rewrite.context.compactMap { messages[$0] }
            default:
                break
            }
        }
        return context
    }

    /// The messages and tools a model call sent, rebuilt from their ids.
    /// Nil when a message or tool set it names isn't in the journal.
    public func request(of call: ModelCallRecord) -> (messages: [Message], tools: [ToolDefinition]?)? {
        let messages = messagesByID
        let rebuilt = call.request.messageIDs.compactMap { messages[$0] }
        guard rebuilt.count == call.request.messageIDs.count else { return nil }
        guard let toolsID = call.request.toolsID else { return (rebuilt, nil) }
        guard let tools = toolsByID[toolsID] else { return nil }
        return (rebuilt, tools)
    }
}
