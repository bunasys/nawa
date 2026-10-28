import AgentCore
import Foundation

/// The directory where the CLI modes keep one journal per session
/// (proposal 0005), named `<started-at>-<session id>.jsonl` so `ls` sorts
/// them by age.
///
/// A session is looked up by listing the directory and matching file names,
/// never by joining a client-chosen id into a path, and only ids shaped like
/// the ones Nawa issues are accepted.
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `$NAWA_SESSIONS_DIR`, else `$XDG_STATE_HOME/nawa/sessions`, else
    /// `~/.local/state/nawa/sessions`. Nil when `NAWA_SESSIONS=off`.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SessionStore? {
        let recordingIsOff = ["off", "0", "false", "no"].contains(env["NAWA_SESSIONS"]?.lowercased() ?? "")
        if recordingIsOff { return nil }
        if let directory = env["NAWA_SESSIONS_DIR"], !directory.isEmpty {
            return SessionStore(directory: URL(fileURLWithPath: directory))
        }
        let stateHome: URL
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            stateHome = URL(fileURLWithPath: xdg)
        } else {
            stateHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        }
        return SessionStore(directory: stateHome.appendingPathComponent("nawa/sessions"))
    }

    // MARK: Names

    /// Where a new session's journal goes.
    public func newJournalURL(sessionID: String, startedAt: Date = Date()) -> URL {
        directory.appendingPathComponent("\(Self.fileTimestamp(startedAt))-\(sessionID).jsonl")
    }

    /// Ids Nawa issues: a UUID (`repl`, Waku) or `sess_` and part of one (ACP).
    public static func isValidSessionID(_ id: String) -> Bool {
        id.wholeMatch(of: /(sess_)?[0-9A-Fa-f-]{8,36}/) != nil
    }

    /// `2026-10-28T08-00-03Z`: ISO 8601 with no colons, which some file
    /// systems refuse.
    static func fileTimestamp(_ date: Date) -> String {
        date.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
    }

    /// The session id in a journal's file name, if it is one of ours.
    static func sessionID(inFileName name: String) -> String? {
        let timestampLength = "2026-10-28T08-00-03Z-".count
        guard name.hasSuffix(".jsonl"), name.count > timestampLength + ".jsonl".count else { return nil }
        let id = String(name.dropFirst(timestampLength).dropLast(".jsonl".count))
        return isValidSessionID(id) ? id : nil
    }

    // MARK: Lookup

    /// Every journal, newest first.
    public func journalURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { Self.sessionID(inFileName: $0) != nil }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    /// The journal of `sessionID`; nil for an unknown or malformed id.
    public func journalURL(forSession sessionID: String) -> URL? {
        guard Self.isValidSessionID(sessionID) else { return nil }
        return journalURLs().first { Self.sessionID(inFileName: $0.lastPathComponent) == sessionID }
    }

    /// The newest session started in `cwd`, by `mode` if given, for
    /// `repl --resume` without an id.
    public func newestSession(inDirectory cwd: String, mode: String? = nil) -> URL? {
        journalURLs().first { url in
            guard case .sessionStarted(let start)? = JournalReader.readFirst(url)?.entry.record else { return false }
            let modeMatches = mode == nil || start.origin.mode == mode
            return start.cwd == cwd && modeMatches
        }
    }

    /// Deletes the journals last written before `date`; returns them.
    public func prune(lastWrittenBefore date: Date) throws -> [URL] {
        var removed: [URL] = []
        for url in journalURLs() {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let modified = attributes[.modificationDate] as? Date, modified < date else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }
}

extension JournalReader {
    /// The first record only, read without loading the whole file: enough
    /// to tell where and when a session started.
    public static func readFirst(_ url: URL) -> JournalLine? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                buffer = buffer[..<newline]
                break
            }
        }
        return try? JournalFormat.decode(Data(buffer))
    }
}

/// One session's totals, for `nawa sessions list`.
public struct SessionSummary: Sendable, Hashable {
    public var sessionID: String
    public var startedAt: Date
    public var cwd: String
    public var mode: String
    public var model: String?
    /// The first prompt, as the user typed it.
    public var firstPrompt: String?
    /// Prompts sent (runs started).
    public var prompts: Int
    /// Model calls, sub-agents' included.
    public var modelCalls: Int
    public var usage: Usage
    /// Nil when no call had a price.
    public var costUSD: Double?

    /// Nil for a journal that never started a session.
    public init?(_ contents: JournalContents) {
        guard let sessionID = contents.mainSessionID,
              let first = contents.entries.first(where: { $0.session == sessionID }),
              case .sessionStarted(let start) = first.record
        else { return nil }
        self.sessionID = sessionID
        self.startedAt = first.at
        self.cwd = start.cwd
        self.mode = start.origin.mode
        self.model = start.model

        let messages = contents.messagesByID
        var prompts = 0
        var firstPrompt: String?
        for entry in contents.entries where entry.session == sessionID {
            guard case .runStarted(let promptID, _) = entry.record else { continue }
            prompts += 1
            if firstPrompt == nil { firstPrompt = messages[promptID]?.text }
        }
        self.prompts = prompts
        self.firstPrompt = firstPrompt

        let calls = contents.modelCalls
        self.modelCalls = calls.count
        self.usage = calls.reduce(into: Usage.zero) { $0.accumulate($1.usage) }
        let prices = calls.compactMap(\.costUSD)
        self.costUSD = prices.isEmpty ? nil : prices.reduce(0, +)
    }
}
