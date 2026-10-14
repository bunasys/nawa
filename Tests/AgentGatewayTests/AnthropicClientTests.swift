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
    func requestMovesSystemToTopLevelAndMergesToolResults() throws {
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
        let body = try AnthropicClient.requestBody(ModelRequest(model: "claude-opus-5-5", messages: messages)).objectValue!
        let turns = body["messages"]!.arrayValue!

        let system = body["system"]?.arrayValue?.first?.objectValue
        #expect(system?["text"]?.stringValue == "Be brief.")
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
    func requestMarksToolsSystemAndNewestMessageCacheable() throws {
        let thinking = JSON.object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")])
        let messages = [
            Message(role: .system, text: "Be brief."),
            Message(role: .user, text: "Echo?"),
            Message(role: .assistant, content: [.toolCall(ToolCall(id: "t1", name: "echo")), .opaque(provider: "anthropic", payload: thinking)]),
        ]
        let tools = [
            ToolDefinition(name: "a", description: ""),
            ToolDefinition(name: "b", description: ""),
        ]
        let body = try AnthropicClient.requestBody(ModelRequest(model: "m", messages: messages, tools: tools)).objectValue!
        let wireTools = body["tools"]!.arrayValue!
        let system = body["system"]!.arrayValue!
        let turns = body["messages"]!.arrayValue!
        let firstTurnBlock = turns[0].objectValue!["content"]!.arrayValue![0].objectValue!
        let lastTurnBlocks = turns[1].objectValue!["content"]!.arrayValue!

        #expect(wireTools[0].objectValue?["cache_control"] == nil)
        #expect(wireTools[1].objectValue?["cache_control"] == AnthropicClient.cacheControl)
        #expect(system[0].objectValue?["cache_control"] == AnthropicClient.cacheControl)
        #expect(firstTurnBlock["cache_control"] == nil)
        // The trailing thinking block refuses cache_control; the tool_use before it takes it.
        #expect(lastTurnBlocks[0].objectValue?["cache_control"] == AnthropicClient.cacheControl)
        #expect(lastTurnBlocks[1] == thinking)
    }

    @Test
    func toolSchemaWithoutTypeIsSentAsObject() throws {
        let tool = ToolDefinition(name: "noop", description: "No parameters.", parameters: .object([:]))
        let body = try AnthropicClient.requestBody(ModelRequest(model: "m", messages: [], tools: [tool])).objectValue!
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

struct AnthropicUsageAndModelTests {
    @Test
    func cacheTokensAreKeptApartFromInput() {
        let usage = AnthropicClient.usage(from: .object([
            "input_tokens": .int(10),
            "cache_read_input_tokens": .int(1000),
            "cache_creation_input_tokens": .int(200),
            "output_tokens": .int(5),
        ]))
        #expect(usage == Usage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 1000, cacheWriteTokens: 200))
        #expect(usage.promptTokens == 1210)
    }

    @Test
    func requestWithoutModelIsRefused() {
        #expect(throws: GatewayError.self) {
            try AnthropicClient.requestBody(ModelRequest(messages: []))
        }
    }
}
