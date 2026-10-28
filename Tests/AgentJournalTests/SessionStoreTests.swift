import AgentCore
import AgentJournal
import Foundation
import Testing

struct SessionStoreTests {
    /// Writes a small session journal: started in `cwd`, one prompt, one call.
    func writeSession(_ store: SessionStore, id: String, cwd: String, startedAt: Date = Date(), prompt: String = "Hi") -> URL {
        let url = store.newJournalURL(sessionID: id, startedAt: startedAt)
        let journal = JournalFile(url: url, origin: JournalOrigin(mode: "repl"))
        let promptMessage = Message(role: .user, text: prompt)
        let call = ModelCallRecord(
            id: "call-1",
            purpose: .turn,
            request: .init(messageIDs: [promptMessage.id], toolsID: nil, model: "m", provider: "p", maxOutputTokens: nil, temperature: nil, streamed: false),
            response: .init(messageID: "reply", stopReason: .endTurn, model: "m", provider: "p", replacedProvider: nil, declinedBy: []),
            usage: Usage(inputTokens: 100, outputTokens: 20),
            costUSD: 0.5,
            startedAt: startedAt,
            firstChunkMS: nil,
            durationMS: 1200,
            failedAttempts: [],
            wire: nil,
            error: nil
        )
        let records: [JournalRecord] = [
            .sessionStarted(SessionStart(origin: journal.origin, cwd: cwd, model: "m", options: .object([:]))),
            .message(promptMessage, appendedToContext: true),
            .runStarted(promptMessageID: promptMessage.id, model: "m"),
            .modelCall(call),
            .message(Message(id: "reply", role: .assistant, text: "Hello."), appendedToContext: true),
        ]
        for record in records {
            journal.record(JournalEntry(session: id, at: startedAt, record: record))
        }
        journal.close()
        return url
    }

    @Test
    func theDirectoryFollowsTheEnvironment() {
        #expect(SessionStore.fromEnvironment(["NAWA_SESSIONS": "off"]) == nil)
        #expect(SessionStore.fromEnvironment(["NAWA_SESSIONS_DIR": "/x/sessions"])?.directory.path == "/x/sessions")
        #expect(SessionStore.fromEnvironment(["XDG_STATE_HOME": "/state"])?.directory.path == "/state/nawa/sessions")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SessionStore.fromEnvironment([:])?.directory.path == home + "/.local/state/nawa/sessions")
    }

    @Test
    func filesAreNamedByStartTimeAndID() throws {
        let store = SessionStore(directory: URL(fileURLWithPath: "/s"))
        let startedAt = try Date("2026-10-28T08:00:03Z", strategy: .iso8601)
        let url = store.newJournalURL(sessionID: "sess_6F1C2A3B-4D5", startedAt: startedAt)
        #expect(url.path == "/s/2026-10-28T08-00-03Z-sess_6F1C2A3B-4D5.jsonl")
    }

    @Test
    func onlyIDsNawaIssuesAreAccepted() {
        #expect(SessionStore.isValidSessionID(UUID().uuidString))
        #expect(SessionStore.isValidSessionID("sess_\(UUID().uuidString.prefix(12))"))
        #expect(!SessionStore.isValidSessionID("../../etc/passwd"))
        #expect(!SessionStore.isValidSessionID("a/b"))
        #expect(!SessionStore.isValidSessionID(""))
    }

    @Test
    func aSessionIsFoundByListingTheDirectory() throws {
        let store = SessionStore(directory: try temporaryDirectory())
        let id = UUID().uuidString
        let url = writeSession(store, id: id, cwd: "/work")
        #expect(store.journalURL(forSession: id) == url)
        #expect(store.journalURL(forSession: UUID().uuidString) == nil)
        #expect(store.journalURL(forSession: "../\(url.lastPathComponent)") == nil)
    }

    @Test
    func theNewestSessionOfADirectoryIsTheOneToResume() throws {
        let store = SessionStore(directory: try temporaryDirectory())
        let now = Date()
        _ = writeSession(store, id: UUID().uuidString, cwd: "/work", startedAt: now.addingTimeInterval(-60))
        let newest = writeSession(store, id: UUID().uuidString, cwd: "/work", startedAt: now)
        _ = writeSession(store, id: UUID().uuidString, cwd: "/elsewhere", startedAt: now.addingTimeInterval(60))
        #expect(store.newestSession(inDirectory: "/work") == newest)
        #expect(store.newestSession(inDirectory: "/nowhere") == nil)
        #expect(store.newestSession(inDirectory: "/work", mode: "repl") == newest)
        #expect(store.newestSession(inDirectory: "/work", mode: "acp") == nil)
    }

    @Test
    func pruneRemovesOnlyJournalsNotWrittenSince() throws {
        let store = SessionStore(directory: try temporaryDirectory())
        let old = writeSession(store, id: UUID().uuidString, cwd: "/work")
        let recent = writeSession(store, id: UUID().uuidString, cwd: "/work")
        let longAgo = Date().addingTimeInterval(-40 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

        let removed = try store.prune(lastWrittenBefore: Date().addingTimeInterval(-30 * 24 * 3600))
        #expect(removed == [old])
        #expect(store.journalURLs() == [recent])
    }

    @Test
    func aSummaryTotalsTheSession() throws {
        let store = SessionStore(directory: try temporaryDirectory())
        let id = UUID().uuidString
        let url = writeSession(store, id: id, cwd: "/work", prompt: "Fix the build")
        let summary = try #require(SessionSummary(JournalReader.read(url)))
        #expect(summary.sessionID == id)
        #expect(summary.cwd == "/work")
        #expect(summary.mode == "repl")
        #expect(summary.firstPrompt == "Fix the build")
        #expect(summary.prompts == 1)
        #expect(summary.modelCalls == 1)
        #expect(summary.usage.total == 120)
        #expect(summary.costUSD == 0.5)
    }

    @Test
    func theFirstRecordIsReadAlone() throws {
        let store = SessionStore(directory: try temporaryDirectory())
        let url = writeSession(store, id: UUID().uuidString, cwd: "/work")
        let first = try #require(JournalReader.readFirst(url))
        #expect(first.seq == 1)
        guard case .sessionStarted(let start) = first.entry.record else {
            Issue.record("first record is not session_started")
            return
        }
        #expect(start.cwd == "/work")
    }

    @Test
    func aResumedStartRoundTrips() throws {
        let start = SessionStart(origin: JournalOrigin(mode: "acp"), cwd: "/w", model: nil, options: .object([:]), resumed: true)
        let line = try JournalFormat.encode(JournalEntry(session: "s", record: .sessionStarted(start)), seq: 1)
        #expect(String(decoding: line, as: UTF8.self).contains(#""resumed":true"#))
        #expect(try JournalFormat.decode(line).entry.record == .sessionStarted(start))
    }
}
