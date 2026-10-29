import AgentCore
import AgentJournal
import AgentLoop
import AgentTUI
import Foundation

/// `nawa sessions list|show|path|prune`: the sessions recorded in the
/// sessions directory (proposal 0005). A summary only; real analysis reads
/// the JSON Lines files with `jq` or DuckDB (`nawa sessions path <id>`).
enum SessionsCommand {
    static let usage = """
        Usage: nawa sessions <command>
          list [--all]               sessions started in this directory (--all: everywhere)
          show <id>                  prompts, model calls, tokens and cost of one session
          path <id>                  the session's journal file, for jq or DuckDB
          prune --older-than <age>   delete journals not written to for <age> (e.g. 30d, 12h, 2w)
        """

    static func run(arguments: [String], sessions: SessionStore?) throws {
        guard let sessions else { throw SessionsError.recordingOff }
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "list":
            let directory = rest.contains("--all") ? nil : WorkingDirectory.defaultURL.path
            print(list(sessions, inDirectory: directory), terminator: "")
        case "show":
            let url = try journal(of: rest.first, in: sessions)
            print(show(JournalReader.read(url), path: url.path), terminator: "")
        case "path":
            print(try journal(of: rest.first, in: sessions).path)
        case "prune":
            guard rest.first == "--older-than", rest.count > 1, let age = parseAge(rest[1]) else {
                throw SessionsError.badAge(rest.dropFirst().first)
            }
            let removed = try sessions.prune(lastWrittenBefore: Date().addingTimeInterval(-age))
            print(removed.count == 1 ? "Removed 1 session." : "Removed \(removed.count) sessions.")
        default:
            print(usage)
        }
    }

    private static func journal(of sessionID: String?, in sessions: SessionStore) throws -> URL {
        guard let sessionID else { throw SessionsError.missingID }
        guard let url = sessions.journalURL(forSession: sessionID) else { throw SessionsError.unknown(sessionID) }
        return url
    }

    /// `30d`, `12h`, `2w` in seconds; nil if it doesn't parse.
    static func parseAge(_ text: String) -> TimeInterval? {
        guard let match = text.wholeMatch(of: /(\d+)([hdw])/), let count = Double(match.1) else { return nil }
        let hour = 3600.0
        switch match.2 {
        case "h": return count * hour
        case "d": return count * 24 * hour
        default: return count * 7 * 24 * hour
        }
    }

    // MARK: list

    /// One line per session, newest first. `directory` nil lists them all.
    static func list(_ sessions: SessionStore, inDirectory directory: String?) -> String {
        var lines: [String] = []
        for url in sessions.journalURLs() {
            // The first line says where it ran, so other directories' files aren't read whole.
            if let directory {
                guard case .sessionStarted(let start)? = JournalReader.readFirst(url)?.entry.record,
                      start.cwd == directory
                else { continue }
            }
            guard let summary = SessionSummary(JournalReader.read(url)) else { continue }
            lines.append(listLine(summary, showDirectory: directory == nil))
        }
        if lines.isEmpty {
            return directory == nil ? "No sessions recorded.\n" : "No sessions recorded in this directory (--all lists every one).\n"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func listLine(_ summary: SessionSummary, showDirectory: Bool) -> String {
        var parts = [
            summary.sessionID,
            localTime(summary.startedAt),
            summary.prompts == 1 ? "1 prompt" : "\(summary.prompts) prompts",
            "\(Format.tokens(summary.usage.total)) tokens",
        ]
        if let cost = summary.costUSD { parts.append(Format.cost(cost)) }
        if showDirectory { parts.append(AgentCLI.displayPath(URL(fileURLWithPath: summary.cwd))) }
        if let prompt = summary.firstPrompt { parts.append(quoted(prompt, limit: 50)) }
        return parts.joined(separator: "  ")
    }

    // MARK: show

    /// A per-prompt and per-call summary of one session.
    static func show(_ contents: JournalContents, path: String) -> String {
        guard let summary = SessionSummary(contents) else { return "Not a session journal: \(path)\n" }
        let calls = contents.modelCalls
        var out: [String] = []

        out.append("Session \(summary.sessionID)")
        var started = ["started \(localTime(summary.startedAt))", summary.mode, AgentCLI.displayPath(URL(fileURLWithPath: summary.cwd))]
        if let model = summary.model { started.append(model) }
        out.append("  " + started.joined(separator: " · "))
        var totals = [
            summary.prompts == 1 ? "1 prompt" : "\(summary.prompts) prompts",
            summary.modelCalls == 1 ? "1 model call" : "\(summary.modelCalls) model calls",
            "\(Format.tokens(summary.usage.total)) tokens" + cacheHit(summary.usage),
        ]
        if let cost = summary.costUSD { totals.append(Format.cost(cost)) }
        out.append("  " + totals.joined(separator: " · "))

        out.append("")
        out.append("Prompts")
        for (number, run) in runs(contents).enumerated() {
            var parts = ["\(number + 1). \(quoted(run.prompt, limit: 60))"]
            parts.append(run.calls == 1 ? "1 call" : "\(run.calls) calls")
            parts.append("\(Format.tokens(run.usage.total)) tokens" + cacheHit(run.usage))
            if let cost = run.cost { parts.append(Format.cost(cost)) }
            parts.append(run.outcome ?? "unfinished")
            out.append("  " + parts.joined(separator: " · "))
        }

        let slowest = calls.sorted { $0.durationMS > $1.durationMS }.prefix(5)
        if !slowest.isEmpty {
            out.append("")
            out.append("Slowest model calls")
            for call in slowest {
                var parts = [seconds(call.durationMS), call.purpose.rawValue]
                if let model = call.response?.model ?? call.request.model { parts.append(model) }
                if let provider = call.response?.provider ?? call.request.provider { parts.append(provider) }
                parts.append("\(Format.tokens(call.usage.total)) tokens")
                if let firstChunk = call.firstChunkMS { parts.append("first chunk \(seconds(firstChunk))") }
                if !call.failedAttempts.isEmpty { parts.append("\(call.failedAttempts.count) failed attempts") }
                if let error = call.error { parts.append("error: \(quoted(error, limit: 60))") }
                out.append("  " + parts.joined(separator: " · "))
            }
        }

        let toolRuns = contents.entries.compactMap { entry -> ToolRunRecord? in
            if case .toolRun(let run) = entry.record { return run }
            return nil
        }
        let largest = toolRuns.sorted { $0.outputChars > $1.outputChars }.prefix(5)
        if !largest.isEmpty {
            out.append("")
            out.append("Largest tool results")
            for run in largest {
                var parts = ["\(Format.tokens(run.outputChars)) chars", run.name, seconds(run.durationMS)]
                if run.isError { parts.append("error") }
                out.append("  " + parts.joined(separator: " · "))
            }
        }

        out.append("")
        out.append("Journal: \(path)")
        return out.joined(separator: "\n") + "\n"
    }

    /// One prompt of the main session, with every call made while it ran
    /// (its sub-agents' and summaries' included).
    struct Run {
        var prompt: String
        var calls = 0
        var usage = Usage.zero
        var cost: Double?
        /// The result kind, once it finished.
        var outcome: String?
    }

    static func runs(_ contents: JournalContents) -> [Run] {
        guard let mainSession = contents.mainSessionID else { return [] }
        let messages = contents.messagesByID
        var runs: [Run] = []
        for entry in contents.entries {
            switch entry.record {
            case .runStarted(let promptID, _) where entry.session == mainSession:
                runs.append(Run(prompt: messages[promptID]?.text ?? ""))
            case .modelCall(let call) where !runs.isEmpty:
                runs[runs.count - 1].calls += 1
                runs[runs.count - 1].usage.accumulate(call.usage)
                if let cost = call.costUSD {
                    runs[runs.count - 1].cost = (runs[runs.count - 1].cost ?? 0) + cost
                }
            case .runFinished(let result) where entry.session == mainSession && !runs.isEmpty:
                runs[runs.count - 1].outcome = result.kind.rawValue
            default:
                break
            }
        }
        return runs
    }

    // MARK: Formatting

    /// ` (cache hit 87%)`, or nothing when no input was sent.
    private static func cacheHit(_ usage: Usage) -> String {
        let prompt = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        guard prompt > 0, usage.cacheReadTokens > 0 else { return "" }
        let percent = Int((Double(usage.cacheReadTokens) / Double(prompt) * 100).rounded())
        return " (cache hit \(percent)%)"
    }

    private static func seconds(_ milliseconds: Int) -> String {
        let tenths = (milliseconds + 50) / 100
        return "\(tenths / 10).\(tenths % 10)s"
    }

    /// First line only, cut to `limit` characters, in quotes.
    private static func quoted(_ text: String, limit: Int) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let cut = firstLine.count > limit ? firstLine.prefix(limit - 1) + "…" : firstLine
        return "\"\(cut)\""
    }

    /// `2026-10-28 10:00` in the local time zone.
    private static func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

enum SessionsError: Error, LocalizedError {
    case recordingOff
    case missingID
    case unknown(String)
    case badAge(String?)

    var errorDescription: String? {
        switch self {
        case .recordingOff: return "sessions aren't recorded: the sessions setting is off"
        case .missingID: return "which session? nawa sessions list shows their ids"
        case .unknown(let id): return "no recorded session \(id)"
        case .badAge(let text): return "prune needs --older-than <age> like 30d, 12h or 2w\(text.map { ", not \($0)" } ?? "")"
        }
    }
}
