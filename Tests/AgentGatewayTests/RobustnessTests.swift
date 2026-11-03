import AgentCore
@testable import AgentGateway
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Replies that are cut off, malformed or oddly shaped. Each test uses its
/// own hosts, since the stub's replies are shared static state keyed by host.
struct OpenAIStreamRobustnessTests {
    private let hello = [Message(role: .user, text: "hi")]

    @Test
    func aStreamCutOffBeforeItsEndIsIncomplete() async throws {
        let host = "cut-off.test"
        let session = StubURLProtocol.session(host: host, replies: [
            .init(pieces: [sse([#"{"choices":[{"delta":{"content":"Hel"}}]}"#])]),
        ])
        let client = OpenAICompatibleClient(providerName: "p", baseURL: URL(string: "https://\(host)/v1")!, session: session)

        let error = await #expect(throws: GatewayError.self) {
            _ = try await collect(client.stream(ModelRequest(model: "m", messages: hello)))
        }
        guard case .incompleteStream = error else { Issue.record("unexpected \(String(describing: error))"); return }
    }

    /// Nothing reached the caller yet, so another provider may still answer.
    @Test
    func aStreamThatEndsBeforeItsFirstChunkFailsOver() async throws {
        let (primary, fallback) = ("empty-stream.primary.test", "empty-stream.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(pieces: [""])])
        let session = StubURLProtocol.session(host: fallback, replies: [
            .init(pieces: [sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]"])]),
        ])
        let gateway = Gateway(
            providers: [
                ProviderConfig(name: "primary", baseURL: URL(string: "https://\(primary)/v1")!, model: "m"),
                ProviderConfig(name: "fallback", baseURL: URL(string: "https://\(fallback)/v1")!, model: "m"),
            ],
            fallbackProviderNames: ["fallback"],
            session: session
        )

        let reply = try await collect(gateway.stream(ModelRequest(messages: hello)))

        #expect(reply.response?.providerName == "fallback")
    }

    @Test
    func aFinishReasonWithoutDoneIsAWholeReply() throws {
        var assembler = OpenAIStreamAssembler()
        _ = try assembler.consume(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#)
        #expect(try assembler.response().message.text == "ok")
    }

    @Test
    func anErrorGivenAsAStringFailsTheStream() {
        var assembler = OpenAIStreamAssembler()
        let error = #expect(throws: GatewayError.self) {
            _ = try assembler.consume(#"{"error":"overloaded"}"#)
        }
        #expect(error.map { "\($0)" }?.contains("overloaded") == true)
    }

    @Test
    func anErrorInAShapeWeCannotReadStillFailsTheStream() {
        var assembler = OpenAIStreamAssembler()
        #expect(throws: GatewayError.self) {
            _ = try assembler.consume(#"{"error":{"message":42}}"#)
        }
    }

    @Test
    func toolCallsWithoutAnIndexAreKeptApartByTheirIds() throws {
        var assembler = OpenAIStreamAssembler()
        for payload in [
            #"{"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"x\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"id":"b","function":{"name":"shell","arguments":"{}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ] {
            _ = try assembler.consume(payload)
        }
        #expect(try assembler.response().message.toolCalls == [
            ToolCall(id: "a", name: "read_file", arguments: .object(["path": .string("x")])),
            ToolCall(id: "b", name: "shell", arguments: .object([:])),
        ])
    }

    /// Cut off by `max_tokens`: the text is kept, so the tool is never run without its arguments.
    @Test
    func streamedToolArgumentsThatAreNotJSONStayText() throws {
        var assembler = OpenAIStreamAssembler()
        _ = try assembler.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"shell","arguments":"{\"comm"}}]}}]}"#)
        _ = try assembler.consume(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        #expect(try assembler.response().message.toolCalls.first?.arguments == .string(#"{"comm"#))
    }

    @Test
    func toolArgumentsThatAreNotJSONStayTextWithoutStreamingToo() throws {
        let data = Data(#"{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"comm"}}]}"#.utf8)
        let message = OpenAICompatibleClient.assistantMessage(from: try JSONDecoder().decode(OpenAIMessageResponse.self, from: data))
        #expect(message.toolCalls.first?.arguments == .string(#"{"comm"#))
    }

    @Test
    func anAnthropicToolInputThatIsNotJSONStaysText() throws {
        let (_, response) = try AnthropicStreamingTests.assemble([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"shell","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(response.message.toolCalls.first?.arguments == .string(#"{"comm"#))
    }

    @Test
    func moreCachedThanPromptTokensNeverCountsNegativeInput() throws {
        let data = Data(#"{"prompt_tokens":10,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":12}}"#.utf8)
        let usage = OpenAICompatibleClient.usage(try JSONDecoder().decode(OpenAIUsage.self, from: data))
        #expect(usage.inputTokens == 0)
    }
}

/// What `Gateway` does with a provider's configuration before any call.
struct GatewayConfigurationTests {
    private let hello = [Message(role: .user, text: "hi")]
    private let answer = StubURLProtocol.Reply(pieces: [#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#])

    @Test
    func aProvidersHeadersReachEveryRequest() async throws {
        let (openAIHost, anthropicHost) = ("headers-openai.test", "headers-anthropic.test")
        _ = StubURLProtocol.session(host: openAIHost, replies: [
            .init(pieces: [#"{"data":[{"id":"m"}]}"#]),
            answer,
            .init(pieces: [sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]"])]),
        ])
        let session = StubURLProtocol.session(host: anthropicHost, replies: [
            .init(pieces: [#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{}}"#]),
        ])
        let custom = ["X-Team": "agents"]
        let gateway = Gateway(
            providers: [
                ProviderConfig(name: "openai", baseURL: URL(string: "https://\(openAIHost)/v1")!, apiKey: "k", headers: custom),
                ProviderConfig(name: "anthropic", api: .anthropic, baseURL: URL(string: "https://\(anthropicHost)")!, apiKey: "k", model: "c", headers: custom),
            ],
            session: session
        )

        _ = try await gateway.complete(ModelRequest(messages: hello))  // discovers the model first
        _ = try await collect(gateway.stream(ModelRequest(messages: hello)))
        _ = try await gateway.complete(ModelRequest(providerName: "anthropic", messages: hello))

        let sent = StubURLProtocol.headers(host: openAIHost) + StubURLProtocol.headers(host: anthropicHost)
        #expect(sent.count == 4)
        #expect(sent.allSatisfy { $0["X-Team"] == "agents" })
        // The models request also waits as long as the provider allows, not URLSession's 60 s.
        #expect(StubURLProtocol.timeouts(host: openAIHost).first == 600)
    }

    @Test
    func anUnsetAPIKeyVariableIsNamedBeforeAnyCall() async throws {
        let host = "unset-key.test"
        let session = StubURLProtocol.session(host: host, replies: [answer])
        let gateway = Gateway(
            providers: [ProviderConfig(name: "p", baseURL: URL(string: "https://\(host)/v1")!, apiKey: "env:NAWA_TEST_SURELY_UNSET_KEY", model: "m")],
            session: session
        )

        let error = await #expect(throws: GatewayError.self) {
            try await gateway.complete(ModelRequest(messages: hello))
        }

        #expect(error.map { "\($0)" }?.contains("environment variable NAWA_TEST_SURELY_UNSET_KEY is not set") == true)
        #expect(StubURLProtocol.bodies(host: host).isEmpty)
        #expect(!GatewayFailover.isProviderUnavailable(GatewayError.configuration("x")))
    }

    @Test
    func aDiscoveredModelIsAskedForOnceAndKept() async throws {
        let host = "discovery-cache.test"
        let session = StubURLProtocol.session(host: host, replies: [
            .init(pieces: [#"{"data":[{"id":"first"},{"id":"second"}]}"#]),
            answer,
            answer,
        ])
        let gateway = Gateway(providers: [ProviderConfig(name: "p", baseURL: URL(string: "https://\(host)/v1")!)], session: session)

        _ = try await gateway.complete(ModelRequest(messages: hello))
        _ = try await gateway.complete(ModelRequest(messages: hello))

        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 3)  // one GET /models, two chats
        #expect(bodies.dropFirst().allSatisfy { $0.contains(#""model":"first""#) })
    }

    @Test
    func aWhitelistNothingAdvertisedIsOnFailsDiscovery() async throws {
        let host = "whitelist-miss.test"
        let session = StubURLProtocol.session(host: host, replies: [.init(pieces: [#"{"data":[{"id":"other"}]}"#])])
        let gateway = Gateway(
            providers: [ProviderConfig(name: "p", baseURL: URL(string: "https://\(host)/v1")!, modelWhitelist: ["wanted"])],
            session: session
        )

        let error = await #expect(throws: GatewayError.self) {
            try await gateway.complete(ModelRequest(messages: hello))
        }

        guard case .modelNotFound(let detail) = error else { Issue.record("unexpected \(String(describing: error))"); return }
        #expect(detail.contains("wanted"))
        #expect(StubURLProtocol.bodies(host: host).count == 1)  // no chat with a model off the list
    }
}
