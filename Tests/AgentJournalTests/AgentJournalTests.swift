import AgentCore
@testable import AgentJournal
import Foundation
import Testing

/// One of every record type, with every optional field set, so a round
/// trip checks each field on both sides.
let everyRecord: [JournalRecord] = [
    .sessionStarted(SessionStart(
        origin: JournalOrigin(mode: "repl", nawaVersion: "0.6.0"),
        cwd: "/work",
        model: "claude-sonnet-5-5",
        options: .object(["max_turns": .int(50)]),
        parent: JournalParent(session: "parent-session", callID: "task-1")
    )),
    .message(Message(id: "m1", role: .assistant, content: [
        .text("Looking."),
        .toolCall(ToolCall(id: "c1", name: "read_file", arguments: .object(["path": .string("a.swift")]))),
        .opaque(provider: "anthropic", payload: .object(["type": .string("thinking"), "signature": .string("sig")])),
    ]), appendedToContext: true),
    .message(Message(id: "m2", role: .tool, content: [
        .toolResult(ToolCallResult(callID: "c1", name: "read_file", content: "\u{1B}[1mbold\u{1B}[0m\nline 2", isError: true)),
    ]), appendedToContext: false),
    .tools(id: "t1", definitions: [ToolDefinition(name: "read_file", description: "Reads a file", parameters: .object(["type": .string("object")]))]),
    .runStarted(promptMessageID: "m0", model: "claude-sonnet-5-5"),
    .modelCall(ModelCallRecord(
        id: "call-1",
        purpose: .turn,
        request: .init(messageIDs: ["m0", "m1"], toolsID: "t1", model: "claude-sonnet-5-5", provider: "anthropic", maxOutputTokens: 8192, temperature: 0.5, streamed: true),
        response: .init(messageID: "m3", stopReason: .toolUse, model: "claude-sonnet-5-5", provider: "anthropic", replacedProvider: "runinfra", declinedBy: ["claude-fable-5-1"]),
        usage: Usage(inputTokens: 312, outputTokens: 406, cacheReadTokens: 48210, cacheWriteTokens: 1840, reasoningTokens: 288),
        costUSD: 0.0231,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000.125),
        firstChunkMS: 2140,
        durationMS: 9479,
        failedAttempts: [FailedAttempt(provider: "runinfra", error: "HTTP 503", durationMS: 812)],
        wire: WireFacts(requestBytes: 214_877, providerRequestID: "req_1", rateLimitHeaders: ["anthropic-ratelimit-requests-remaining": "3998"]),
        error: nil
    )),
    .modelCall(ModelCallRecord(
        id: "call-2",
        purpose: .compaction,
        request: .init(messageIDs: ["s1", "s2"], toolsID: nil, model: nil, provider: nil, maxOutputTokens: nil, temperature: nil, streamed: false),
        response: nil,
        usage: .zero,
        costUSD: nil,
        startedAt: Date(timeIntervalSince1970: 1_800_000_010),
        firstChunkMS: nil,
        durationMS: 30,
        failedAttempts: [],
        wire: nil,
        error: "network error: offline"
    )),
    .toolRun(ToolRunRecord(callID: "c1", name: "read_file", startedAt: Date(timeIntervalSince1970: 1_800_000_001), durationMS: 4, outputChars: 120, isError: false)),
    .contextRewrite(ContextRewrite(reason: .compaction, removed: ["m1", "m2"], added: ["m9"], context: ["m0", "m9", "m3"], modelCallID: "call-2")),
    .steered(messageID: "m4"),
    .noteSaved("The config lives in Sources/Config.swift"),
    .modelChanged(from: "claude-sonnet-5-5", to: nil),
    .refusal(RefusalNotice(declinedBy: "claude-fable-5-1", category: "cyber", explanation: "policy", answeredBy: "claude-opus-5-5")),
    .runFinished(AgentResult(
        kind: .success,
        text: "Done.",
        usage: Usage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4),
        numTurns: 3,
        sessionID: "s",
        stopReason: .endTurn,
        costEstimate: 0.5,
        errorMessage: "none",
        refusal: RefusalNotice(declinedBy: "a", answeredBy: "b")
    )),
]

/// A fresh, empty directory for one test.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct JournalFormatTests {
    @Test
    func everyRecordRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000.481)
        for (index, record) in everyRecord.enumerated() {
            let entry = JournalEntry(session: "s", at: at, record: record)
            let line = try JournalFormat.encode(entry, seq: index + 1)
            #expect(!line.contains(UInt8(ascii: "\n")), "one record per line")
            let decoded = try JournalFormat.decode(line)
            #expect(decoded.seq == index + 1)
            #expect(decoded.entry.record.sameType(as: record))
            // Compared as lines: a decoded date can differ from the
            // original below a millisecond, which the format doesn't keep.
            #expect(try JournalFormat.encode(decoded.entry, seq: index + 1) == line)
        }
    }

    /// The field names are the format's contract with outside tools: a
    /// rename must fail here, not in someone's DuckDB query.
    @Test
    func modelCallUsesTheDocumentedFieldNames() throws {
        let entry = JournalEntry(session: "s", at: Date(timeIntervalSince1970: 0), record: everyRecord[5])
        let line = try JournalFormat.encode(entry, seq: 7)
        let json = try JSONDecoder().decode(JSON.self, from: line).objectValue ?? [:]

        #expect(json["v"] == .int(1))
        #expect(json["type"] == .string("model_call"))
        #expect(json["seq"] == .int(7))
        #expect(json["at"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(json["session"] == .string("s"))
        let request = json["request"]?.objectValue ?? [:]
        #expect(request["messages"] == .array([.string("m0"), .string("m1")]))
        #expect(request["tools"] == .string("t1"))
        let usage = json["usage"]?.objectValue ?? [:]
        #expect(usage["cache_read_tokens"] == .int(48210))
        #expect(usage["reasoning_tokens"] == .int(288))
        let timing = json["timing"]?.objectValue ?? [:]
        #expect(timing["first_chunk_ms"] == .int(2140))
        let wire = json["wire"]?.objectValue ?? [:]
        #expect(wire["request_bytes"] == .int(214_877))
        #expect(wire["rate_limit"]?.objectValue?["anthropic-ratelimit-requests-remaining"] == .string("3998"))
        #expect(json["failed_attempts"]?.arrayValue?.count == 1)
    }

    @Test
    func missingValuesAreLeftOut() throws {
        let entry = JournalEntry(session: "s", record: .modelChanged(from: nil, to: "a"))
        let json = try JSONDecoder().decode(JSON.self, from: try JournalFormat.encode(entry, seq: 1)).objectValue ?? [:]
        #expect(json["from"] == nil)
        #expect(json["to"] == .string("a"))
    }

    @Test
    func aNewerVersionIsRefused() throws {
        let line = Data(#"{"v":2,"type":"note_saved","seq":1,"at":"2026-10-28T08:00:00.000Z","session":"s","note":"x"}"#.utf8)
        #expect(throws: JournalFormatError.unsupportedVersion(2)) { try JournalFormat.decode(line) }
    }
}

struct JournalFileTests {
    @Test
    func appendsNumberedLinesAndReadsThemBack() throws {
        let url = try temporaryDirectory().appendingPathComponent("sessions/a.jsonl")
        let journal = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        for record in everyRecord {
            journal.record(JournalEntry(session: "s", record: record))
        }
        journal.close()

        let contents = JournalReader.read(url)
        #expect(contents.skippedLines == 0)
        #expect(contents.lines.map(\.seq) == Array(1...everyRecord.count))
        #expect(contents.entries.map(\.record) == everyRecord)
    }

    @Test
    func reopeningContinuesTheSequence() throws {
        let url = try temporaryDirectory().appendingPathComponent("a.jsonl")
        let first = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        first.record(JournalEntry(session: "s", record: .noteSaved("one")))
        first.record(JournalEntry(session: "s", record: .noteSaved("two")))
        first.close()

        let second = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        second.record(JournalEntry(session: "s", record: .noteSaved("three")))
        second.close()

        #expect(JournalReader.read(url).lines.map(\.seq) == [1, 2, 3])
    }

    @Test
    func filesAreReadableByTheOwnerOnly() throws {
        let directory = try temporaryDirectory().appendingPathComponent("private")
        let url = directory.appendingPathComponent("a.jsonl")
        let journal = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        journal.record(JournalEntry(session: "s", record: .noteSaved("secret")))
        journal.close()

        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    /// A crash can cut the last line short; only that line is lost, also
    /// once a later process appends to the file.
    @Test
    func aCutOffLineCostsOnlyItself() throws {
        let url = try temporaryDirectory().appendingPathComponent("a.jsonl")
        let first = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        first.record(JournalEntry(session: "s", record: .noteSaved("kept")))
        first.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"type":"note_sa"#.utf8))
        try handle.close()

        let second = JournalFile(url: url, origin: JournalOrigin(mode: "library"))
        second.record(JournalEntry(session: "s", record: .noteSaved("after the crash")))
        second.close()

        let contents = JournalReader.read(url)
        #expect(contents.skippedLines == 1)
        #expect(contents.entries.map(\.record) == [.noteSaved("kept"), .noteSaved("after the crash")])
    }

    @Test
    func aFailedWriteReportsOnceAndStops() throws {
        // A regular file where the directory should be: nothing can be created under it.
        let blocker = try temporaryDirectory().appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let failures = FailureLog()
        let journal = JournalFile(url: blocker.appendingPathComponent("a.jsonl"), origin: JournalOrigin(mode: "library")) { message in
            failures.append(message)
        }

        journal.record(JournalEntry(session: "s", record: .noteSaved("one")))
        journal.record(JournalEntry(session: "s", record: .noteSaved("two")))

        #expect(failures.messages.count == 1)
        #expect(failures.messages.first?.contains("recording stopped") == true)
    }

    @Test
    func aMissingFileReadsAsEmpty() throws {
        let url = try temporaryDirectory().appendingPathComponent("none.jsonl")
        #expect(JournalReader.read(url).lines.isEmpty)
    }
}

final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

extension JournalRecord {
    /// Whether two records are the same case, ignoring their values.
    func sameType(as other: JournalRecord) -> Bool {
        String(describing: self).prefix(while: { $0 != "(" }) == String(describing: other).prefix(while: { $0 != "(" })
    }
}
