@testable import AgentACP
import AgentCore
import AgentGateway
import AgentJSONRPC
import AgentLoop
import AgentMCP
import Synchronization
import Testing

/// Never answers a prompt that says "hang" (until cancelled); answers "ok"
/// to anything else, and remembers every prompt it was sent.
final class HangingModel: LanguageModel, Sendable {
    let providerName = "hanging"
    private let recorded = Mutex<[String]>([])

    var prompts: [String] { recorded.withLock { $0 } }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let prompt = request.messages.last { $0.role == .user }?.text ?? ""
        recorded.withLock { $0.append(prompt) }
        if prompt == "hang" { try await Task.sleep(for: .seconds(600)) }
        return ModelResponse(message: Message(role: .assistant, text: "ok"), finishReason: .endTurn)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

struct HangingFactory: ACPSessionFactory {
    var model = HangingModel()
    var options = LoopOptions(streamReplies: false)

    func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        AgentLoop(gateway: model, tools: ToolRegistry([]), options: options, cwd: cwd)
    }
}

/// Drives one connection the way a stdio client does: requests in, every
/// reply and update out on the one stream.
struct ACPClientHarness {
    let connection: ACPConnection
    private var outbound: AsyncStream<JSONRPCMessage>.Iterator
    /// The notifications seen while waiting for replies.
    private(set) var updates: [JSON] = []

    init(factory: any ACPSessionFactory, capabilities: ACPCapabilities = .init()) async {
        connection = ACPConnection(connectionID: "test", factory: factory, capabilities: capabilities, routing: .singleStream)
        outbound = await connection.outbound.makeAsyncIterator()
    }

    mutating func send(_ method: String, id: JSONRPCID, _ params: [String: JSON]) async {
        await connection.handle(.request(JSONRPCRequest(method: method, id: id, params: .object(params))))
    }

    mutating func reply(to id: JSONRPCID) async -> JSON? {
        while let message = await outbound.next() {
            if message.id == id { return message.json }
            if let update = message.json.objectValue?["params"]?.objectValue?["update"] { updates.append(update) }
        }
        return nil
    }

    mutating func newSession() async throws -> String {
        await send("session/new", id: "new", ["cwd": .string("/tmp")])
        return try #require(await reply(to: "new")?.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue)
    }

    mutating func startPrompt(_ sessionID: String, id: JSONRPCID, _ text: String) async {
        await send("session/prompt", id: id, [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    }

    mutating func cancel(_ sessionID: String) async {
        await connection.handle(.notification(JSONRPCMethod(method: "session/cancel", params: .object(["sessionId": .string(sessionID)]))))
    }

    static func stopReason(_ reply: JSON?) -> String? {
        reply?.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPTurnTests {
    @Test
    func aCancelledTurnStopsAsCancelled() async throws {
        var client = await ACPClientHarness(factory: HangingFactory())
        let sessionID = try await client.newSession()
        await client.startPrompt(sessionID, id: 1, "hang")
        await client.cancel(sessionID)
        #expect(ACPClientHarness.stopReason(await client.reply(to: 1)) == "cancelled")
    }

    /// The second prompt cancels the first, which still gets its answer,
    /// and then runs on its own.
    @Test
    func aNewPromptRunsOnceTheCancelledOneHasAnswered() async throws {
        let model = HangingModel()
        var client = await ACPClientHarness(factory: HangingFactory(model: model))
        let sessionID = try await client.newSession()
        await client.startPrompt(sessionID, id: 1, "hang")
        await client.startPrompt(sessionID, id: 2, "hi")
        #expect(ACPClientHarness.stopReason(await client.reply(to: 1)) == "cancelled")
        #expect(ACPClientHarness.stopReason(await client.reply(to: 2)) == "end_turn")
        #expect(model.prompts.last == "hi")
    }

    /// The replay would interleave with the running turn's updates.
    @Test
    func loadingASessionMidTurnIsRefused() async throws {
        var client = await ACPClientHarness(factory: HangingFactory(), capabilities: ACPCapabilities(loadSession: true))
        let sessionID = try await client.newSession()
        await client.startPrompt(sessionID, id: 1, "hang")
        await client.send("session/load", id: 2, ["sessionId": .string(sessionID), "cwd": .string("/tmp")])
        let error = await client.reply(to: 2)?.objectValue?["error"]?.objectValue
        #expect(error?["code"]?.intValue == JSONRPCErrorCode.invalidRequest.rawValue)
        await client.cancel(sessionID)
        _ = await client.reply(to: 1)
    }

    /// Clients show `used / size` as how full the context is.
    @Test
    func usageReportsTheCompactionPointAsTheSize() async throws {
        let options = LoopOptions(compaction: Compaction(atContextTokens: 120_000), streamReplies: false)
        var client = await ACPClientHarness(factory: HangingFactory(options: options))
        let sessionID = try await client.newSession()
        await client.startPrompt(sessionID, id: 1, "hi")
        _ = await client.reply(to: 1)
        let usage = client.updates.first { $0.objectValue?["sessionUpdate"]?.stringValue == "usage_update" }
        #expect(usage?.objectValue?["size"]?.intValue == 120_000)
    }

    @Test
    func resourcesReachTheModelAsText() async throws {
        let model = HangingModel()
        var client = await ACPClientHarness(factory: HangingFactory(model: model))
        let sessionID = try await client.newSession()
        await client.send("session/prompt", id: 1, [
            "sessionId": .string(sessionID),
            "prompt": .array([
                .object(["type": .string("text"), "text": .string("Review these")]),
                .object(["type": .string("resource"), "resource": .object([
                    "uri": .string("file:///a.swift"), "text": .string("let a = 1"),
                ])]),
                .object(["type": .string("resource_link"), "uri": .string("file:///b.swift"), "name": .string("b.swift")]),
                .object(["type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/png")]),
            ]),
        ])
        _ = await client.reply(to: 1)
        #expect(model.prompts == ["Review these\n<file uri=\"file:///a.swift\">\nlet a = 1\n</file>\n@file:///b.swift"])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPConnectionLifecycleTests {
    @Test
    func aStreamHasOneReaderAtATime() async throws {
        let connection = ACPConnection(connectionID: "test", factory: HangingFactory())
        guard case .stream = await connection.attachStream(.connection) else {
            Issue.record("the first reader was refused")
            return
        }
        guard case .alreadyAttached = await connection.attachStream(.connection) else {
            Issue.record("a second reader was let in")
            return
        }
        await connection.detachStream(.connection)
        guard case .stream = await connection.attachStream(.connection) else {
            Issue.record("a reconnecting reader was refused")
            return
        }
    }

    /// A client must not be able to make the server buffer for sessions
    /// that don't exist.
    @Test
    func onlyExistingSessionsHaveStreams() async throws {
        let connection = ACPConnection(connectionID: "test", factory: HangingFactory())
        guard case .unknownSession = await connection.attachStream(.session("sess_made_up")) else {
            Issue.record("a made-up session got a stream")
            return
        }
    }

    @Test
    func closingCancelsTurnsAndEndsTheStream() async throws {
        var client = await ACPClientHarness(factory: HangingFactory())
        let sessionID = try await client.newSession()
        await client.startPrompt(sessionID, id: 1, "hang")
        await client.connection.close()
        // Ends instead of waiting forever for the hung turn.
        _ = await client.reply(to: "never")
        await client.send("session/new", id: 2, [:])
        #expect(await client.reply(to: 2) == nil)
    }

    /// Sessions talk back to their connection, which owns them: that link
    /// must not keep a dropped connection alive.
    @Test
    func aDroppedConnectionIsFreed() async throws {
        var connection: ACPConnection? = ACPConnection(connectionID: "test", factory: HangingFactory(), routing: .singleStream)
        weak let observed = connection
        var outbound = await connection!.outbound.makeAsyncIterator()
        await connection!.handle(.request(JSONRPCRequest(method: "session/new", id: 1, params: .object(["cwd": .string("/tmp")]))))
        #expect(await outbound.next()?.id == 1)
        connection = nil
        #expect(observed == nil)
    }
}

struct ACPDecodingTests {
    /// ACP sends environment variables as `[{"name", "value"}]`.
    @Test
    func mcpServerEnvironmentIsNameValuePairs() {
        let servers = ACPConnection.decodeMCPServers(.array([
            .object([
                "name": .string("files"),
                "command": .string("/usr/bin/files-mcp"),
                "args": .array([.string("--root"), .string("/tmp")]),
                "env": .array([.object(["name": .string("TOKEN"), "value": .string("abc")])]),
            ]),
            .object(["type": .string("http"), "name": .string("remote"), "url": .string("https://mcp.example")]),
        ]))
        #expect(servers == [MCPServerConfig(name: "files", command: "/usr/bin/files-mcp", args: ["--root", "/tmp"], env: ["TOKEN": "abc"])])
    }

    @Test
    func aBinaryResourceIsLeftOut() {
        let blob = JSON.object(["type": .string("resource"), "resource": .object(["uri": .string("file:///a.png"), "blob": .string("AAAA")])])
        #expect(ACPContentBlock(json: blob) == nil)
    }
}
