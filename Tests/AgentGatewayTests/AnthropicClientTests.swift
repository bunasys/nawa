import AgentCore
@testable import AgentGateway
import Foundation
import Testing

struct AnthropicClientTests {
    @Test
    func baseURLGainsV1OnlyWhenMissing() {
        let bare = AnthropicClient.versionedBaseURL(URL(string: "https://api.anthropic.com")!)
        let versioned = AnthropicClient.versionedBaseURL(URL(string: "https://proxy.example.com/anthropic/v1")!)
        #expect(bare.absoluteString == "https://api.anthropic.com/v1")
        #expect(versioned.absoluteString == "https://proxy.example.com/anthropic/v1")
    }

    @Test
    func requestMovesSystemToTopLevelAndMergesToolResults() {
        let thinking = JSON.object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")])
        let messages = [
            Message(role: .system, text: "Be brief."),
            Message(role: .user, text: "Time and echo?"),
            Message(role: .assistant, content: [
                .opaque(provider: "anthropic", payload: thinking),
                .toolCall(ToolCall(id: "t1", name: "time")),
                .toolCall(ToolCall(id: "t2", name: "echo", arguments: .object(["text": .string("hi")]))),
            ]),
            Message(role: .tool, content: [.toolResult(ToolCallResult(callID: "t1", name: "time", content: "noon"))]),
            Message(role: .tool, content: [.toolResult(ToolCallResult(callID: "t2", name: "echo", content: "hi"))]),
        ]
        let body = AnthropicClient.requestBody(ModelRequest(model: "claude-opus-5-5", messages: messages)).objectValue!
        let turns = body["messages"]!.arrayValue!

        #expect(body["system"]?.stringValue == "Be brief.")
        #expect(body["max_tokens"]?.intValue == AnthropicClient.defaultMaxTokens)
        #expect(body["temperature"] == nil)
        #expect(turns.count == 3)
        let assistantBlocks = turns[1].objectValue!["content"]!.arrayValue!
        #expect(assistantBlocks.first == thinking)
        let toolTurn = turns[2].objectValue!
        #expect(toolTurn["role"]?.stringValue == "user")
        #expect(toolTurn["content"]?.arrayValue?.count == 2)
    }

    @Test
    func toolSchemaWithoutTypeIsSentAsObject() {
        let tool = ToolDefinition(name: "noop", description: "No parameters.", parameters: .object([:]))
        let body = AnthropicClient.requestBody(ModelRequest(model: "m", messages: [], tools: [tool])).objectValue!
        let schema = body["tools"]?.arrayValue?.first?.objectValue?["input_schema"]?.objectValue
        #expect(schema?["type"]?.stringValue == "object")
    }

    @Test
    func otherProvidersOpaqueBlocksAreNotSent() {
        let foreign = ContentBlock.opaque(provider: "someone-else", payload: .object([:]))
        #expect(AnthropicClient.anthropicBlock(foreign) == nil)
        #expect(AnthropicClient.anthropicBlock(.text("")) == nil)
    }

    @Test
    func responseParsesTextToolUseThinkingAndUsage() throws {
        let reply = JSON.object([
            "content": .array([
                .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")]),
                .object(["type": .string("text"), "text": .string("Checking.")]),
                .object([
                    "type": .string("tool_use"), "id": .string("t1"), "name": .string("echo"),
                    "input": .object(["text": .string("hi")]),
                ]),
            ]),
            "stop_reason": .string("tool_use"),
            "usage": .object(["input_tokens": .int(12), "output_tokens": .int(5)]),
        ])
        let response = try AnthropicClient.modelResponse(from: reply, providerName: "test")

        #expect(response.message.text == "Checking.")
        #expect(response.message.toolCalls.first?.name == "echo")
        #expect(response.finishReason == .toolUse)
        #expect(response.usage.inputTokens == 12)
        guard case .opaque(let provider, _) = response.message.content.first else {
            Issue.record("thinking block was not kept")
            return
        }
        #expect(provider == "anthropic")
    }

    @Test
    func providerConfigWithoutAPIDecodesAsOpenAI() throws {
        let data = Data(#"{"name":"old","baseURL":"https://api.openai.com/v1"}"#.utf8)
        let config = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(config.api == nil)
        #expect(try Gateway(providers: [config]).client() is OpenAICompatibleClient)
    }

    @Test
    func gatewayPassesConfiguredWorkspace() throws {
        let config = ProviderConfig(
            name: "claude", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-api", workspaceID: "wrkspc_1"
        )
        let client = try #require(try Gateway(providers: [config]).client() as? AnthropicClient)
        #expect(client.workspaceID == "wrkspc_1")
    }

    @Test
    func gatewayRoutesAnthropicProviders() throws {
        let config = ProviderConfig(name: "claude", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!)
        #expect(try Gateway(providers: [config]).client() is AnthropicClient)
    }
}
