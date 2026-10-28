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

// MARK: Replay

extension JournalContents {
    /// The session that isn't a sub-agent's, i.e. the one the file was opened for.
    public var mainSessionID: String? {
        for entry in entries {
            if case .sessionStarted(let start) = entry.record, start.parent == nil {
                return entry.session
            }
        }
        return nil
    }

    /// Rebuilds what a loop needs to go on with `session` (by default the
    /// main session) where the journal leaves it. Nil when the journal
    /// never started that session.
    public func replay(session: String? = nil) -> SessionState? {
        guard let sessionID = session ?? mainSessionID else { return nil }
        var start: SessionStart?
        var model: String?
        var notes: [String] = []
        var usage = Usage.zero
        var helperUsage = Usage.zero
        var contextTokens = 0
        var subAgentSessions: Set<String> = []

        for entry in entries {
            if entry.session != sessionID {
                // Sub-agents spend on the parent's account, as the loop counts them.
                if case .sessionStarted(let child) = entry.record, child.parent?.session == sessionID {
                    subAgentSessions.insert(entry.session)
                }
                if subAgentSessions.contains(entry.session), case .modelCall(let call) = entry.record {
                    usage.accumulate(call.usage)
                    helperUsage.accumulate(call.usage)
                }
                continue
            }
            switch entry.record {
            case .sessionStarted(let started):
                // A resumed session has one per process; the first says where it began.
                if start == nil { start = started }
                model = started.model
            case .modelChanged(_, let to):
                model = to
            case .noteSaved(let note):
                notes.append(note)
            case .modelCall(let call):
                usage.accumulate(call.usage)
                if call.purpose == .compaction {
                    helperUsage.accumulate(call.usage)
                } else if call.response != nil {
                    contextTokens = call.usage.total
                }
            case .contextRewrite(let rewrite) where rewrite.reason != .toolResultsCleared:
                // The loop waits for the next call to report the new size.
                contextTokens = 0
            default:
                break
            }
        }
        guard let start else { return nil }
        return SessionState(
            sessionID: sessionID,
            cwd: start.cwd,
            model: model,
            messages: context(ofSession: sessionID),
            notes: notes,
            usage: usage,
            helperUsage: helperUsage,
            contextTokens: contextTokens
        )
    }
}
