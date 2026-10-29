import AgentCore
import Foundation

/// Ways to make the conversation smaller before it is sent again.
///
/// Every turn resends the whole conversation, so old tool output is paid for
/// over and over. Both strategies here rewrite *old* messages, which
/// invalidates the provider's prompt cache from that point on; that is why
/// they run rarely and in big steps rather than a little every turn.
enum ContextShrinking {
    /// How a cleared tool result starts. Older journals used
    /// `legacyElidedResult`; both count as cleared.
    static let elidedPrefix = "[elided to save context:"
    static let legacyElidedResult = "[result elided to save context; run the tool again if you need it]"

    static func isElided(_ content: String) -> Bool {
        content.hasPrefix(elidedPrefix) || content == legacyElidedResult
    }

    /// What a cleared result becomes: one line saying what it was, so the
    /// model knows what it had and can run the call again if it needs it.
    /// `[elided to save context: read_file {"path":"a.py"} returned 412 lines; run it again if you need it]`
    static func elidedNote(for result: ToolCallResult, call: ToolCall?) -> String {
        var arguments = call?.arguments.description ?? ""
        if arguments.count > 160 { arguments = String(arguments.prefix(159)) + "…" }
        let invocation = arguments.isEmpty ? result.name : "\(result.name) \(arguments)"
        let lineCount = result.content.split(separator: "\n", omittingEmptySubsequences: false).count
        let outcome = result.isError ? "failed" : "returned \(lineCount) \(lineCount == 1 ? "line" : "lines")"
        return "\(elidedPrefix) \(invocation) \(outcome); run it again if you need it]"
    }

    /// Clear old tool results, newest kept, in large batches.
    ///
    /// Clearing starts when either limit is passed:
    /// - `keep`: more than `2 × keep` results are still whole;
    /// - `maxChars`: the whole results add up to more than `maxChars`.
    /// It then keeps the newest results, at most `keep` of them and
    /// `maxChars / 2` characters (the newest one always), and replaces the
    /// rest with a one-line note. Clearing a little every turn would change
    /// the conversation prefix every turn and defeat prompt caching; halving
    /// means the next clearing is many turns away.
    static func clearingOldToolResults(_ messages: [Message], keep: Int?, maxChars: Int? = nil) -> [Message] {
        var positions: [(message: Int, block: Int, size: Int)] = []
        var callsByID: [String: ToolCall] = [:]
        for (messageIndex, message) in messages.enumerated() {
            for (blockIndex, block) in message.content.enumerated() {
                switch block {
                case .toolCall(let call):
                    callsByID[call.id] = call
                case .toolResult(let result) where !isElided(result.content):
                    positions.append((messageIndex, blockIndex, result.content.count))
                default:
                    break
                }
            }
        }
        let totalChars = positions.reduce(0) { $0 + $1.size }
        let isTooMany = keep.map { positions.count > 2 * $0 } ?? false
        let isTooBig = maxChars.map { totalChars > $0 } ?? false
        guard isTooMany || isTooBig else { return messages }

        var keptCount = 0
        var keptChars = 0
        for position in positions.reversed() {
            let fitsCount = keep.map { keptCount < $0 } ?? true
            let fitsSize = maxChars.map { keptChars + position.size <= $0 / 2 } ?? true
            guard keptCount == 0 || (fitsCount && fitsSize) else { break }
            keptCount += 1
            keptChars += position.size
        }

        var cleared = messages
        var changedMessages = Set<Int>()
        for position in positions.dropLast(keptCount) {
            guard case .toolResult(var result) = cleared[position.message].content[position.block] else { continue }
            result.content = elidedNote(for: result, call: callsByID[result.callID])
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

    /// Below this size a repeated result is cheaper to send again than to explain.
    static let repeatedOutputMinChars = 512

    /// Results whose text equals a result still whole in the conversation
    /// (or earlier in the same batch) become a short pointer to it.
    ///
    /// Typical case: reading a file again that hasn't changed. Only the
    /// context gets the pointer; callers keep the real results for events,
    /// the UI and the loop check. If the earlier result is cleared later,
    /// the pointer says to run the tool again, which then returns the text
    /// in full because nothing whole matches it any more.
    static func dedupingRepeatedResults(_ results: [ToolCallResult], against messages: [Message]) -> [ToolCallResult] {
        var earlier: [String: ToolCallResult] = [:]
        for message in messages {
            for case .toolResult(let result) in message.content where isWorthDeduping(result) {
                earlier[result.content] = earlier[result.content] ?? result
            }
        }
        return results.map { result in
            guard isWorthDeduping(result) else { return result }
            guard let original = earlier[result.content] else {
                earlier[result.content] = result
                return result
            }
            var pointer = result
            pointer.content = "[same output as the earlier \(original.name) call \(original.callID): refer to that result. "
                + "If it has been elided since, run the tool again.]"
            return pointer
        }
    }

    private static func isWorthDeduping(_ result: ToolCallResult) -> Bool {
        !result.isError && result.content.count >= repeatedOutputMinChars && !isElided(result.content)
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
    You compress the history of a coding agent's session so the agent can continue the \
    task without it. If the history starts with an earlier summary, update that summary \
    with what happened since rather than starting over. Write notes to the agent, not a \
    narrative, under these headings, leaving out any that would be empty:

    ## Goal
    ## Constraints and preferences
    ## Done
    ## In progress
    ## Key decisions
    ## Next steps
    ## Critical context

    Keep exact file paths, function names, commands, error messages and numbers. Drop \
    anything that doesn't help finish the task. The lists of files read and changed are \
    added for you; don't repeat them.
    """

    static let summaryHeader = """
    Summary of the conversation so far (older messages were compacted). It is background \
    for the task: go on from the newest messages below it.
    """
    static let filesReadPrefix = "Files read: "
    static let filesChangedPrefix = "Files changed: "
    /// The newest this many paths are kept per list.
    static let maxListedFiles = 60

    /// The files read and changed in `messages`, taken from `read_file` and
    /// `edit_file` calls and from an earlier summary's lists, oldest first.
    /// Built in code rather than by the summarizer so they stay exact.
    static func fileLists(in messages: [Message]) -> (read: [String], changed: [String]) {
        var read: [String] = []
        var changed: [String] = []
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text) where text.hasPrefix(summaryHeader):
                    for line in text.split(separator: "\n") {
                        if line.hasPrefix(filesReadPrefix) { read += listedPaths(line.dropFirst(filesReadPrefix.count)) }
                        if line.hasPrefix(filesChangedPrefix) { changed += listedPaths(line.dropFirst(filesChangedPrefix.count)) }
                    }
                case .toolCall(let call):
                    guard let path = call.arguments.objectValue?["path"]?.stringValue else { continue }
                    if call.name == "read_file" { read.append(path) }
                    if call.name == "edit_file" { changed.append(path) }
                default:
                    break
                }
            }
        }
        return (newestUnique(read), newestUnique(changed))
    }

    private static func listedPaths(_ line: Substring) -> [String] {
        line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Each path once, at its latest position, at most `maxListedFiles`.
    private static func newestUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var newestFirst: [String] = []
        for path in paths.reversed() where !seen.contains(path) {
            seen.insert(path)
            newestFirst.append(path)
        }
        return Array(newestFirst.prefix(maxListedFiles).reversed())
    }

    /// The message that stands in for the compacted messages.
    static func summaryText(_ summary: String, notes: [String], files: (read: [String], changed: [String])) -> String {
        var text = summaryHeader + "\n\n" + summary
        if !notes.isEmpty {
            text += "\n\nNotes you saved with remember:\n" + notes.map { "- \($0)" }.joined(separator: "\n")
        }
        var fileLines: [String] = []
        if !files.read.isEmpty { fileLines.append(filesReadPrefix + files.read.joined(separator: ", ")) }
        if !files.changed.isEmpty { fileLines.append(filesChangedPrefix + files.changed.joined(separator: ", ")) }
        if !fileLines.isEmpty { text += "\n\n" + fileLines.joined(separator: "\n") }
        return text
    }
}
