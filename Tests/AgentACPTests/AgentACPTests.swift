@testable import AgentACP
import AgentGateway
import AgentLoop
import AgentMCP
import AgentTools
import AgentCore
import AgentJSONRPC
import Testing

struct AgentACPTests {
    @Test
    func contentBlockTextRoundTrips() {
        let block = ACPContentBlock.text("hello")
        let json = block.json
        let decoded = ACPContentBlock(json: json)
        #expect(decoded != nil)
        if case .text(let t) = decoded! { #expect(t == "hello") } else { Issue.record("not text") }
    }

    @Test
    func stopReasonFromDomain() {
        #expect(ACPStopReason(domain: .endTurn) == .endTurn)
        #expect(ACPStopReason(domain: .maxTokens) == .maxTokens)
        #expect(ACPStopReason(domain: .refusal) == .refusal)
        #expect(ACPStopReason(domain: nil) == .endTurn)
    }

    @Test
    func stopReasonFromResultKind() {
        #expect(ACPStopReason(resultKind: .success) == .endTurn)
        #expect(ACPStopReason(resultKind: .errorMaxTurns) == .maxTurnRequests)
        #expect(ACPStopReason(resultKind: .errorDuringExecution) == .refusal)
    }

    @Test
    func sessionUpdateToolCallShape() {
        let json = ACPSessionUpdate.toolCall(callID: "c1", title: "Reading", kind: .read, status: .pending)
        let obj = json.objectValue!
        #expect(obj["sessionUpdate"]?.stringValue == "tool_call")
        #expect(obj["toolCallId"]?.stringValue == "c1")
        #expect(obj["kind"]?.stringValue == "read")
        #expect(obj["status"]?.stringValue == "pending")
    }

    @Test
    func messageChunkShape() {
        let json = ACPSessionUpdate.messageChunk(kind: .agentMessageChunk, messageID: "m1", content: .text("hi"))
        let obj = json.objectValue!
        #expect(obj["sessionUpdate"]?.stringValue == "agent_message_chunk")
        #expect(obj["messageId"]?.stringValue == "m1")
        #expect(obj["content"]?.objectValue?["type"]?.stringValue == "text")
    }

    @Test
    func jsonrpcRequestSerializes() {
        let msg = JSONRPCMessage.makeRequest(method: "session/prompt", id: 42, params: .object(["sessionId": .string("s1")]))
        let obj = msg.json.objectValue!
        #expect(obj["jsonrpc"]?.stringValue == "2.0")
        #expect(obj["method"]?.stringValue == "session/prompt")
        #expect(obj["id"]?.intValue == 42)
        #expect(obj["params"]?.objectValue?["sessionId"]?.stringValue == "s1")
    }

    @Test
    func eventStreamBuffersUntilConsumed() async {
        let stream = ACPEventStream()
        stream.publish(.makeSuccess(id: 1, result: .object([:])))
        let first = await stream.stream.first { _ in true }
        #expect(first != nil)
        #expect(first?.id == 1)
    }
}

/// Remembers the model id each request asked for and always answers "ok".
final class ModelRecorder: LanguageModel, @unchecked Sendable {
    var requestedModels: [String?] = []
    let providerName = "recorder"

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requestedModels.append(request.model)
        return ModelResponse(message: Message(role: .assistant, text: "ok"), finishReason: .endTurn)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

struct RecorderFactory: ACPSessionFactory {
    let model: ModelRecorder

    func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        AgentLoop(gateway: model, tools: ToolRegistry([]), cwd: cwd)
    }
}

struct ACPSingleChannelTests {
    /// The stdio flow Waku drives: initialize → session/new → session/set_model
    /// → session/prompt, with every reply arriving on the one outbound stream.
    @Test
    func stdioFlowAppliesSelectedModel() async throws {
        let recorder = ModelRecorder()
        let connection = ACPConnection(connectionID: "test", factory: RecorderFactory(model: recorder), routing: .singleStream)
        var outbound = await connection.outbound.makeAsyncIterator()

        await connection.handle(.request(JSONRPCRequest(method: "initialize", id: 0, params: .object([:]))))
        let initialize = await outbound.next()
        #expect(initialize?.json.objectValue?["result"]?.objectValue?["protocolVersion"]?.intValue == 1)

        await connection.handle(.request(JSONRPCRequest(method: "session/new", id: 1, params: .object(["cwd": .string("/tmp")]))))
        let created = await outbound.next()
        let sessionID = try #require(created?.json.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue)

        await connection.handle(.request(JSONRPCRequest(method: "session/set_model", id: 2, params: .object([
            "sessionId": .string(sessionID), "modelId": .string("claude-opus-5-5"),
        ]))))
        #expect(await outbound.next()?.id == 2)

        await connection.handle(.request(JSONRPCRequest(method: "session/prompt", id: 3, params: .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
        ]))))
        var promptReply: JSONRPCMessage?
        while let message = await outbound.next() {
            if message.id == 3 { promptReply = message; break }
        }
        #expect(promptReply?.json.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue == "end_turn")
        #expect(recorder.requestedModels == ["claude-opus-5-5"])
    }
}

/// Fails every request the way a rejected API key does.
struct UnauthorizedModel: LanguageModel {
    let providerName = "unauthorized"

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        throw GatewayError.httpError(statusCode: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

struct UnauthorizedFactory: ACPSessionFactory {
    func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        AgentLoop(gateway: UnauthorizedModel(), tools: ToolRegistry([]), cwd: cwd)
    }
}

struct ACPErrorReportingTests {
    /// Clients show a JSON-RPC error's message to the user, so a failed turn
    /// must arrive as one, carrying the provider's own explanation.
    @Test
    func failedTurnIsAJSONRPCErrorWithTheProviderMessage() async throws {
        let connection = ACPConnection(connectionID: "test", factory: UnauthorizedFactory(), routing: .singleStream)
        var outbound = await connection.outbound.makeAsyncIterator()

        await connection.handle(.request(JSONRPCRequest(method: "session/new", id: 1, params: .object(["cwd": .string("/tmp")]))))
        let sessionID = try #require(await outbound.next()?.json.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue)

        await connection.handle(.request(JSONRPCRequest(method: "session/prompt", id: 2, params: .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
        ]))))
        var reply: JSONRPCMessage?
        while let message = await outbound.next() {
            if message.id == 2 { reply = message; break }
        }

        let error = try #require(reply?.json.objectValue?["error"]?.objectValue)
        let message = try #require(error["message"]?.stringValue)
        #expect(message.contains("HTTP 401"))
        #expect(message.contains("invalid x-api-key"))
    }
}

struct JSONRPCIDTests {
    /// Waku's ACP library sends UUID string ids; a request with one must be
    /// parsed as a request (not a notification) and answered with the same id.
    @Test
    func stringIDRequestIsAnsweredWithTheSameID() async throws {
        let line = #"{"jsonrpc":"2.0","id":"6f1c-uuid","method":"initialize","params":{"protocolVersion":1}}"#
        let parsed = try parseJSONRPCLine(line)
        guard case .request(let request) = parsed else {
            Issue.record("string-id request parsed as \(parsed)")
            return
        }
        #expect(request.id == "6f1c-uuid")

        let connection = ACPConnection(connectionID: "test", factory: RecorderFactory(model: ModelRecorder()), routing: .singleStream)
        var outbound = await connection.outbound.makeAsyncIterator()
        await connection.handle(parsed)
        let reply = await outbound.next()
        #expect(reply?.json.objectValue?["id"] == .string("6f1c-uuid"))
    }
}

struct JSONRPCResponseIDTests {
    /// A response that names no request must not be matched to request `0`.
    @Test
    func successResponseWithoutIDIsRejected() {
        #expect(throws: JSONRPCParseError.self) {
            try parseJSONRPCLine(#"{"jsonrpc":"2.0","result":{}}"#)
        }
    }
}
