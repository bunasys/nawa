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

    /// `$NAWA_SESSIONS_DIR`, else `defaultDirectory`. Nil when
    /// `NAWA_SESSIONS=off`.
    ///
    /// Kept for library users. Nawa's CLI reads those two variables as
    /// settings (`sessions`, `sessions_dir`) and calls `defaultDirectory`.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SessionStore? {
        let recordingIsOff = ["off", "0", "false", "no"].contains(env["NAWA_SESSIONS"]?.lowercased() ?? "")
        if recordingIsOff { return nil }
        if let directory = env["NAWA_SESSIONS_DIR"], !directory.isEmpty {
            return SessionStore(directory: URL(fileURLWithPath: directory))
        }
        return SessionStore(directory: defaultDirectory(environment: env))
    }

    /// `$XDG_STATE_HOME/nawa/sessions`, else `~/.local/state/nawa/sessions`.
    /// Reads only `XDG_STATE_HOME` and `HOME`.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        stateDirectory(environment: environment).appendingPathComponent("sessions")
    }

    /// Nawa's state directory: `$XDG_STATE_HOME/nawa`, else
    /// `~/.local/state/nawa`. Sessions and `serve`'s token file live in it.
    public static func stateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let stateHome: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            stateHome = URL(fileURLWithPath: xdg)
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            stateHome = URL(fileURLWithPath: home).appendingPathComponent(".local/state")
        }
        return stateHome.appendingPathComponent("nawa")
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
    public static func sessionID(inFileName name: String) -> String? {
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

    /// The session in `cwd` written to most recently, by `mode` if given,
    /// for `repl --resume` without an id. Last written, not last started:
    /// a session resumed today is newer than one started this morning.
    public func newestSession(inDirectory cwd: String, mode: String? = nil) -> URL? {
        var lastWritten: [URL: Date] = [:]
        for url in journalURLs() {
            lastWritten[url] = Self.modificationDate(of: url) ?? .distantPast
        }
        let lastWrittenFirst = lastWritten.keys.sorted { lastWritten[$0]! > lastWritten[$1]! }
        return lastWrittenFirst.first { url in
            guard case .sessionStarted(let start)? = JournalReader.readFirst(url)?.entry.record else { return false }
            let modeMatches = mode == nil || start.origin.mode == mode
            return start.cwd == cwd && modeMatches
        }
    }

    /// What `pruneJournals` did.
    public struct PruneResult: Sendable, Hashable {
        public var removed: [URL] = []
        /// Old enough, but open in a running nawa.
        public var inUse: [URL] = []
        /// Old enough, but removing them failed.
        public var failed: [URL] = []
    }

    /// Deletes the journals last written before `date`, except those a
    /// running nawa has open. A file that vanishes or can't be removed
    /// meanwhile is skipped, so one problem doesn't hide what was done.
    public func pruneJournals(lastWrittenBefore date: Date) -> PruneResult {
        var result = PruneResult()
        for url in journalURLs() {
            guard let modified = Self.modificationDate(of: url), modified < date else { continue }
            if JournalFile.isInUse(url) {
                result.inUse.append(url)
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                result.removed.append(url)
            } catch {
                result.failed.append(url)
            }
        }
        return result
    }

    /// Deletes the journals last written before `date`; returns them.
    /// `pruneJournals` also says which were skipped.
    public func prune(lastWrittenBefore date: Date) throws -> [URL] {
        pruneJournals(lastWrittenBefore: date).removed
    }

    /// Nil when the file is gone or can't be read.
    static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
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
