import AgentCore
@testable import AgentGateway
import Foundation
import Testing

/// Refusals (`stop_reason: "refusal"`) and Anthropic's server-side fallback.
struct RefusalTests {
    private func decode(_ text: String) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
    }

    @Test
    func serverFallbacksAreAskedForOnlyWhenOn() throws {
        let request = ModelRequest(model: "claude-opus-5-5", messages: [Message(role: .user, text: "hi")])
        let with = try AnthropicClient.requestBody(request, serverFallbacks: true).objectValue!
        let without = try AnthropicClient.requestBody(request).objectValue!
        #expect(with["fallbacks"] == .string("default"))
        #expect(without["fallbacks"] == nil)
    }

    @Test
    func serverFallbacksDefaultToOnForAnthropicsOwnAPIOnly() {
        let anthropic = ProviderConfig(name: "a", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!)
        let proxy = ProviderConfig(name: "p", api: .anthropic, baseURL: URL(string: "https://proxy.example.com/v1")!)
        let proxyOptedIn = ProviderConfig(name: "p", api: .anthropic, baseURL: URL(string: "https://proxy.example.com/v1")!, serverFallbacks: true)
        let anthropicOptedOut = ProviderConfig(name: "a", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, serverFallbacks: false)
        let openAI = ProviderConfig(name: "o", baseURL: URL(string: "https://api.anthropic.com")!, serverFallbacks: true)
        #expect(anthropic.usesServerFallbacks)
        #expect(!proxy.usesServerFallbacks)
        #expect(proxyOptedIn.usesServerFallbacks)
        #expect(!anthropicOptedOut.usesServerFallbacks)
        #expect(!openAI.usesServerFallbacks)
    }

    @Test
    func aRefusalCarriesItsCategoryAndModel() throws {
        let reply = try decode("""
            {"model": "claude-opus-5-5", "content": [], "stop_reason": "refusal",
             "stop_details": {"type": "refusal", "category": "cyber", "explanation": "Could enable cyber harm.", "recommended_model": "claude-opus-4-8"},
             "usage": {"input_tokens": 412, "output_tokens": 0}}
            """)
        let response = try AnthropicClient.modelResponse(from: reply, providerName: "test")
        #expect(response.finishReason == .refusal)
        #expect(response.model == "claude-opus-5-5")
        #expect(response.refusal == RefusalDetails(category: "cyber", explanation: "Could enable cyber harm.", recommendedModel: "claude-opus-4-8"))
        #expect(response.declinedBy.isEmpty)
    }

    @Test
    func refusalDetailsAreOnlySetOnARefusal() throws {
        let reply = try decode(#"{"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn", "stop_details": null}"#)
        #expect(try AnthropicClient.modelResponse(from: reply, providerName: "test").refusal == nil)
    }

    /// After a mid-output fallback, the declined model's tool call must not
    /// run and its thinking must not go back; its text and the marker stay.
    @Test
    func aServerSideFallbackKeepsTheAnswerAndDropsWhatTheDeclinedModelStarted() throws {
        let reply = try decode("""
            {"model": "claude-opus-4-8", "stop_reason": "end_turn", "stop_details": null,
             "content": [
               {"type": "thinking", "thinking": "", "signature": "s1"},
               {"type": "text", "text": "Let me look. "},
               {"type": "tool_use", "id": "t1", "name": "shell", "input": {"command": "ls"}},
               {"type": "fallback", "from": {"model": "claude-opus-5-5"}, "to": {"model": "claude-opus-4-8"}},
               {"type": "text", "text": "Here is the answer."}
             ],
             "usage": {"input_tokens": 400, "output_tokens": 20, "iterations": [
               {"type": "message", "model": "claude-opus-5-5", "input_tokens": 500, "output_tokens": 30, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0},
               {"type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 400, "output_tokens": 20, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 50}
             ]}}
            """)
        let response = try AnthropicClient.modelResponse(from: reply, providerName: "test")
        #expect(response.model == "claude-opus-4-8")
        #expect(response.declinedBy == ["claude-opus-5-5"])
        #expect(response.message.toolCalls.isEmpty)
        #expect(response.message.text == "Let me look. Here is the answer.")
        let kinds = response.message.content.map { block -> String in
            switch block {
            case .text: "text"
            case .toolCall: "tool_use"
            case .opaque(_, let payload): payload.objectValue?["type"]?.stringValue ?? "?"
            case .toolResult: "tool_result"
            }
        }
        #expect(kinds == ["text", "fallback", "text"])
        // Every attempt is counted, the declined one included.
        #expect(response.usage == Usage(inputTokens: 900, outputTokens: 50, cacheReadTokens: 100, cacheWriteTokens: 50))
    }

    @Test
    func theFallbackMarkerGoesBackWhereItWas() throws {
        let marker = JSON.object(["type": .string("fallback"), "from": .object(["model": .string("a")]), "to": .object(["model": .string("b")])])
        let messages = [
            Message(role: .user, text: "hi"),
            Message(role: .assistant, content: [.opaque(provider: "anthropic", payload: marker), .text("hello")]),
            Message(role: .user, text: "again"),
        ]
        let body = try AnthropicClient.requestBody(ModelRequest(model: "m", messages: messages)).objectValue!
        let assistant = body["messages"]!.arrayValue![1].objectValue!["content"]!.arrayValue!
        #expect(assistant.first == marker)
    }

    @Test
    func aStreamedRefusalCarriesItsDetails() throws {
        var assembler = AnthropicStreamAssembler(providerName: "test")
        let events = [
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sure, first"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}},"usage":{"output_tokens":3}}"#,
            #"{"type":"message_stop"}"#,
        ]
        for event in events { _ = try assembler.consume(event) }
        let response = try assembler.response()
        #expect(response.finishReason == .refusal)
        #expect(response.model == "claude-opus-5-5")
        #expect(response.refusal?.category == "cyber")
        #expect(response.refusal?.explanation == nil)
    }

    @Test
    func aModelThatRejectsServerFallbacksIsAskedAgainWithout() async throws {
        let host = "no-fallbacks.test"
        let ok = StubURLProtocol.Reply(pieces: [#"{"model":"m","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#])
        let session = StubURLProtocol.session(host: host, replies: [
            .init(status: 400, pieces: [#"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: not supported for this model"}}"#]),
            ok, ok,
        ])
        let client = AnthropicClient(providerName: "p", baseURL: URL(string: "https://\(host)")!, apiKey: "k", serverFallbacks: true, session: session)
        let request = ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")])

        #expect(try await client.complete(request).message.text == "ok")
        // Remembered: the next request goes without it straight away.
        #expect(try await client.complete(request).message.text == "ok")
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 3)
        #expect(bodies[0].contains("fallbacks"))
        #expect(!bodies[1].contains("fallbacks") && !bodies[2].contains("fallbacks"))
    }
}
