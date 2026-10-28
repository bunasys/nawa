import AgentCore
@testable import AgentGateway
import Foundation
import Testing

struct AgentGatewayTests {
    @Test
    func providerConfigResolvesEnvAPIKey() {
        setenv("TEST_ACP_KEY", "secret123", 1)
        let config = ProviderConfig(name: "p", baseURL: URL(string: "https://example.com/v1")!, apiKey: "env:TEST_ACP_KEY")
        #expect(config.resolvedAPIKey == "secret123")
    }

    @Test
    func openAIMessagesMapRoles() {
        let messages = [
            Message(role: .system, text: "You are helpful."),
            Message(role: .user, text: "Hi"),
            Message(role: .assistant, content: [.text("Sure"), .toolCall(ToolCall(id: "c1", name: "echo", arguments: .object([:])))]),
            Message(role: .tool, content: [.toolResult(ToolCallResult(callID: "c1", name: "echo", content: "hi"))]),
        ]
        let wire = OpenAICompatibleClient.openAIMessages(messages)
        #expect(wire.count == 4)
        #expect(wire[0].role == .system)
        #expect(wire[1].role == .user)
        #expect(wire[2].role == .assistant)
        #expect(wire[2].toolCalls?.count == 1)
        #expect(wire[3].role == .tool)
        #expect(wire[3].toolCallID == "c1")
    }

    @Test
    func stopReasonMaps() {
        #expect(OpenAICompatibleClient.stopReason(from: "stop") == .endTurn)
        #expect(OpenAICompatibleClient.stopReason(from: "tool_calls") == .toolUse)
        #expect(OpenAICompatibleClient.stopReason(from: "length") == .maxTokens)
        #expect(OpenAICompatibleClient.stopReason(from: "content_filter") == .refusal)
        #expect(OpenAICompatibleClient.stopReason(from: "unknown") == nil)
    }

    @Test
    func cachedPromptTokensAreCountedApart() throws {
        let data = Data(#"{"prompt_tokens":1000,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":800}}"#.utf8)
        let usage = OpenAICompatibleClient.usage(try JSONDecoder().decode(OpenAIUsage.self, from: data))
        #expect(usage == Usage(inputTokens: 200, outputTokens: 7, cacheReadTokens: 800))
    }

    @Test
    func reasoningTokensAreKept() throws {
        let data = Data(#"{"prompt_tokens":10,"completion_tokens":500,"completion_tokens_details":{"reasoning_tokens":420}}"#.utf8)
        let usage = OpenAICompatibleClient.usage(try JSONDecoder().decode(OpenAIUsage.self, from: data))
        #expect(usage == Usage(inputTokens: 10, outputTokens: 500, reasoningTokens: 420))
    }
}
