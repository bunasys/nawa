import AgentCore
import Foundation

/// Ways to make the conversation smaller before it is sent again.
///
/// Every turn resends the whole conversation, so old tool output is paid for
/// over and over. Both strategies here rewrite *old* messages, which
/// invalidates the provider's prompt cache from that point on; that is why
/// they run rarely and in big steps rather than a little every turn.
enum ContextShrinking {
    /// What an old tool result is replaced with.
    static let elidedResult = "[result elided to save context; run the tool again if you need it]"

    /// Replace all but the newest `keep` tool results with a short marker.
    ///
    /// Clearing starts only once `2 × keep` results have piled up and then
    /// goes back down to `keep`. Clearing one result per turn would change
    /// the conversation prefix every turn and defeat prompt caching.
    static func clearingOldToolResults(_ messages: [Message], keep: Int) -> [Message] {
        var positions: [(message: Int, block: Int)] = []
        for (messageIndex, message) in messages.enumerated() {
            for (blockIndex, block) in message.content.enumerated() {
                guard case .toolResult(let result) = block, result.content != elidedResult else { continue }
                positions.append((messageIndex, blockIndex))
            }
        }
        guard positions.count > 2 * keep else { return messages }

        var cleared = messages
        var changedMessages = Set<Int>()
        for position in positions.dropLast(keep) {
            guard case .toolResult(var result) = cleared[position.message].content[position.block] else { continue }
            result.content = elidedResult
            cleared[position.message].content[position.block] = .toolResult(result)
            changedMessages.insert(position.message)
        }
        // The journal refers to messages by id, so an id must always mean
        // the same content: a changed message is a new message.
        for index in changedMessages {
            cleared[index].id = UUID().uuidString
        }
        return cleared
    }

    /// Where to cut the conversation for compaction: messages before the
    /// returned index get summarized, the rest are kept word for word.
    ///
    /// Leading system messages are never summarized. The kept part must not
    /// start with tool results, because their tool calls would be in the
    /// summarized part and providers reject a result without its call.
    /// Returns nil when there is nothing worth summarizing.
    static func compactionCut(_ messages: [Message], keepRecent: Int) -> Int? {
        let firstNonSystem = messages.firstIndex { $0.role != .system } ?? messages.count
        var cut = max(firstNonSystem, messages.count - keepRecent)
        while cut < messages.count, messages[cut].role == .tool {
            cut += 1
        }
        let summarizesSomething = cut - firstNonSystem >= 2
        let keepsSomething = cut < messages.count
        guard summarizesSomething, keepsSomething else { return nil }
        return cut
    }

    /// The conversation as plain text for the summarizer. Tool output is
    /// shortened: the summary needs what was learned, not every line.
    static func transcript(_ messages: [Message]) -> String {
        let maxToolOutput = 2_000
        var lines: [String] = []
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text) where !text.isEmpty:
                    lines.append("\(message.role.rawValue): \(text)")
                case .toolCall(let call):
                    lines.append("assistant called \(call.name)(\(call.arguments.description))")
                case .toolResult(let result):
                    let output = result.content.count > maxToolOutput
                        ? String(result.content.prefix(maxToolOutput)) + " […]"
                        : result.content
                    lines.append("\(result.name) returned\(result.isError ? " an error" : ""): \(output)")
                default:
                    break
                }
            }
        }
        return lines.joined(separator: "\n\n")
    }

    static let summarizerInstructions = """
    You compress the history of a coding agent's session so the agent can \
    continue the task without it. Write a concise summary that keeps: the \
    user's goals and constraints, decisions made and why, files and code \
    locations involved, what was changed, what was tried and failed, and \
    what remains to do. Drop anything that does not help finish the task. \
    Write it as notes to the agent, not as a narrative.
    """
}
