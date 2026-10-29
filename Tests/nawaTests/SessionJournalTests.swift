import AgentInstructions
@testable import AgentACP
import AgentCore
import AgentGateway
import AgentJSONRPC
import AgentJournal
import AgentLoop
import Foundation
import Synchronization
import Testing
@testable import nawa

/// Answers "ok" to everything and keeps every request it got.
final class RecordingModel: LanguageModel, Sendable {
    let providerName = "recording"
    private let received = Mutex<[ModelRequest]>([])

    var requests: [ModelRequest] { received.withLock { $0 } }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        received.withLock { $0.append(request) }
        return ModelResponse(message: Message(role: .assistant, text: "ok"), finishReason: .endTurn)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-sessions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One ACP connection over the real `HarnessSessionFactory`, journals in a
/// scratch directory: what `nawa acp` runs, minus stdio.
struct ACPHarness {
    let connection: ACPConnection
    var outbound: AsyncStream<JSONRPCMessage>.AsyncIterator
    private var nextID = 100

    init(sessions: SessionStore?, model: RecordingModel) async {
        let factory = HarnessSessionFactory(
            gatewayForDirectory: { _ in model },
            loopOptions: LoopOptions(streamReplies: false),
            sessions: sessions,
            mode: "acp"
        )
        await self.init(factory: factory, capabilities: ACPCapabilities(loadSession: sessions != nil))
    }

    init(factory: HarnessSessionFactory, capabilities: ACPCapabilities) async {
        connection = ACPConnection(connectionID: "test", factory: factory, capabilities: capabilities, routing: .singleStream)
        outbound = await connection.outbound.makeAsyncIterator()
    }

    /// Sends a request; returns its reply and the notifications before it.
    mutating func call(_ method: String, _ params: [String: JSON]) async -> (reply: JSONRPCMessage?, updates: [JSON]) {
        nextID += 1
        let id = JSONRPCID.number(nextID)
        await connection.handle(.request(JSONRPCRequest(method: method, id: id, params: .object(params))))
        var updates: [JSON] = []
        while let message = await outbound.next() {
            if message.id == id { return (message, updates) }
            if let update = message.json.objectValue?["params"]?.objectValue?["update"] { updates.append(update) }
        }
        return (nil, updates)
    }

    mutating func newSession(cwd: URL) async throws -> String {
        let reply = await call("session/new", ["cwd": .string(cwd.path)]).reply
        return try #require(reply?.json.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue)
    }

    mutating func prompt(_ sessionID: String, _ text: String) async -> String? {
        let reply = await call("session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]).reply
        return reply?.json.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue
    }
}

extension JSONRPCMessage {
    var errorMessage: String? {
        json.objectValue?["error"]?.objectValue?["message"]?.stringValue
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SessionJournalTests {
    @Test
    func anACPSessionIsRecordedUnderItsOwnID() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await acp.newSession(cwd: try scratchDirectory())
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")

        let url = try #require(sessions.journalURL(forSession: sessionID))
        let contents = JournalReader.read(url)
        #expect(contents.mainSessionID == sessionID)
        guard case .sessionStarted(let start)? = contents.entries.first?.record else {
            Issue.record("the journal doesn't start with session_started")
            return
        }
        #expect(start.origin.mode == "acp")
        #expect(start.origin.nawaVersion == ACPServerInfo.nawa.version)
    }

    @Test
    func loadingASessionInANewProcessReplaysItsConversation() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        let cwd = try scratchDirectory()
        var first = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await first.newSession(cwd: cwd)
        #expect(await first.prompt(sessionID, "hi") == "end_turn")

        // A new connection knows nothing of the session but its journal.
        let model = RecordingModel()
        var second = await ACPHarness(sessions: sessions, model: model)
        let (reply, updates) = await second.call("session/load", ["sessionId": .string(sessionID), "cwd": .string(cwd.path), "mcpServers": .array([])])
        #expect(reply?.errorMessage == nil)
        let replayed = updates.map { update in
            [update.objectValue?["sessionUpdate"]?.stringValue ?? "", update.objectValue?["content"]?.objectValue?["text"]?.stringValue ?? ""]
        }
        #expect(replayed == [["user_message_chunk", "hi"], ["agent_message_chunk", "ok"]])

        #expect(await second.prompt(sessionID, "again") == "end_turn")
        // Every session starts with the system prompt (proposal 0006); it comes back with the rest.
        let sentMessages = try #require(model.requests.last).messages
        #expect(sentMessages.first?.role == .system)
        #expect(sentMessages.first?.text.hasPrefix(SystemPrompt.firstPrinciples) == true)
        #expect(sentMessages.first?.text.contains("You are Nawa") == true)
        let sent = sentMessages.filter { $0.role != .system }.map(\.text)
        #expect(sent == ["hi", "ok", "again"])
    }

    @Test
    func unknownOrMalformedSessionsAreNotLoaded() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        for id in ["sess_00000000-000", "../../etc/passwd"] {
            let reply = await acp.call("session/load", ["sessionId": .string(id), "cwd": .string("/tmp")]).reply
            #expect(reply?.errorMessage == "session \(id) not found")
        }
    }

    @Test
    func withoutJournalsSessionsCantBeLoaded() async throws {
        var acp = await ACPHarness(sessions: nil, model: RecordingModel())
        let reply = await acp.call("session/load", ["sessionId": .string("sess_00000000-000")]).reply
        #expect(reply?.errorMessage != nil)
        #expect(await acp.connection.initializeResult().objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue == false)
    }

    @Test
    func anUnloadedSessionComesBackOnItsNextPrompt() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        let model = RecordingModel()
        var acp = await ACPHarness(sessions: sessions, model: model)
        let sessionID = try await acp.newSession(cwd: try scratchDirectory())
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")

        await acp.connection.unloadIdleSessions(idleFor: .zero)
        #expect(await !acp.connection.isLoaded(sessionID))

        #expect(await acp.prompt(sessionID, "again") == "end_turn")
        #expect(await acp.connection.isLoaded(sessionID))
        #expect(try #require(model.requests.last).messages.filter { $0.role != .system }.map(\.text) == ["hi", "ok", "again"])
    }

    @Test
    func aSessionThatCantBeRebuiltSaysWhy() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        let model = RecordingModel()
        // The provider config breaks after the session was created.
        let configBroken = Mutex(false)
        let factory = HarnessSessionFactory(
            gatewayForDirectory: { _ in
                if configBroken.withLock({ $0 }) { throw CLIError.invalidGatewayURL("nowhere") }
                return model
            },
            loopOptions: LoopOptions(streamReplies: false),
            sessions: sessions
        )
        var acp = await ACPHarness(factory: factory, capabilities: ACPCapabilities(loadSession: true))
        let sessionID = try await acp.newSession(cwd: try scratchDirectory())
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")
        await acp.connection.unloadIdleSessions(idleFor: .zero)
        configBroken.withLock { $0 = true }

        let reply = await acp.call("session/prompt", ["sessionId": .string(sessionID), "prompt": .array([])]).reply
        #expect(reply?.errorMessage?.hasPrefix("could not restore the session:") == true)
        #expect(reply?.errorMessage?.contains("nowhere") == true)

        let unknown = await acp.call("session/prompt", ["sessionId": .string("sess_00000000-000"), "prompt": .array([])]).reply
        #expect(unknown?.errorMessage == "unknown session")
    }

    @Test
    func theIdleTimeoutIsReadInMinutes() {
        let fromEnvironment = { (value: String) in
            AgentCLI.idleSessionTimeout(minutes: Settings.fromEnvironment(["NAWA_SESSION_IDLE_MINUTES": value], reportProblems: false).sessionIdleMinutes)
        }
        #expect(AgentCLI.idleSessionTimeout(minutes: nil) == .seconds(30 * 60))
        #expect(fromEnvironment("5") == .seconds(5 * 60))
        #expect(fromEnvironment("0.5") == .seconds(30))
        // Nonsense falls back to the default.
        #expect(fromEnvironment("soon") == .seconds(30 * 60))
        #expect(fromEnvironment("-1") == .seconds(30 * 60))
    }

    @Test
    func idleSessionsAreUnloadedOnTheirOwn() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await acp.newSession(cwd: try scratchDirectory())
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")

        await acp.connection.startUnloadingIdleSessions(after: .zero, checkingEvery: .milliseconds(10))
        var waited = 0
        while await acp.connection.isLoaded(sessionID), waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(await !acp.connection.isLoaded(sessionID))
    }

    @Test
    func onlySessionsQuietForLongEnoughAreUnloaded() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await acp.newSession(cwd: try scratchDirectory())

        // Never prompted: no journal yet to rebuild it from.
        await acp.connection.unloadIdleSessions(idleFor: .zero)
        #expect(await acp.connection.isLoaded(sessionID))

        #expect(await acp.prompt(sessionID, "hi") == "end_turn")
        await acp.connection.unloadIdleSessions(idleFor: .seconds(60))
        #expect(await acp.connection.isLoaded(sessionID))
    }

    // MARK: repl

    @Test
    func resumeFindsTheNamedOrTheNewestSession() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        let cwd = try scratchDirectory()
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await acp.newSession(cwd: cwd)
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")

        let named = try #require(try AgentCLI.resumedSession(arguments: ["--resume", sessionID], sessions: sessions))
        #expect(named.state.sessionID == sessionID)
        #expect(named.state.messages.filter { $0.role != .system }.map(\.text) == ["hi", "ok"])

        // Without an id, only repl sessions are picked up.
        #expect(throws: CLIError.self) {
            try AgentCLI.resumedSession(arguments: ["--plain", "--resume"], sessions: sessions, directory: cwd)
        }

        #expect(try AgentCLI.resumedSession(arguments: ["--plain"], sessions: sessions) == nil)
        #expect(throws: CLIError.self) {
            try AgentCLI.resumedSession(arguments: ["--resume"], sessions: sessions, directory: URL(fileURLWithPath: "/nowhere"))
        }
        #expect(throws: CLIError.self) {
            try AgentCLI.resumedSession(arguments: ["--resume"], sessions: nil)
        }
    }

    // MARK: nawa sessions

    @Test
    func agesParse() {
        let hour: TimeInterval = 3600
        #expect(SessionsCommand.parseAge("12h") == 12 * hour)
        #expect(SessionsCommand.parseAge("30d") == 30 * 24 * hour)
        #expect(SessionsCommand.parseAge("2w") == 14 * 24 * hour)
        #expect(SessionsCommand.parseAge("30") == nil)
        #expect(SessionsCommand.parseAge("d") == nil)
    }

    @Test
    func listAndShowSummarizeASession() async throws {
        let sessions = SessionStore(directory: try scratchDirectory())
        let cwd = try scratchDirectory()
        var acp = await ACPHarness(sessions: sessions, model: RecordingModel())
        let sessionID = try await acp.newSession(cwd: cwd)
        #expect(await acp.prompt(sessionID, "hi") == "end_turn")
        #expect(await acp.prompt(sessionID, "again") == "end_turn")

        let list = SessionsCommand.list(sessions, inDirectory: cwd.path)
        #expect(list.hasPrefix(sessionID))
        #expect(list.contains("2 prompts"))
        #expect(list.contains("\"hi\""))
        #expect(SessionsCommand.list(sessions, inDirectory: "/nowhere").hasPrefix("No sessions recorded in this directory"))

        let url = try #require(sessions.journalURL(forSession: sessionID))
        let shown = SessionsCommand.show(JournalReader.read(url), path: url.path)
        #expect(shown.contains("Session \(sessionID)"))
        #expect(shown.contains("1. \"hi\" · 1 call"))
        #expect(shown.contains("2. \"again\" · 1 call"))
        #expect(shown.contains("success"))
        #expect(shown.hasSuffix("Journal: \(url.path)\n"))
    }
}
