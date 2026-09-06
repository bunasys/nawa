@testable import AgentACP
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
