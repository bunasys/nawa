import AgentCore
@testable import AgentGateway
import AgentLoop
import AgentTools
import Foundation
import Testing

/// A scripted language model for deterministic loop tests.
///
/// A final class so the call counter can advance across invocations without
/// violating mutability rules on struct methods.
final class ScriptedModel: LanguageModel, @unchecked Sendable {
    nonisolated let providerName = "scripted"
    var responses: [ModelResponse]
    var callIndex = 0

    init(responses: [ModelResponse]) {
        self.responses = responses
    }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let response = responses[min(callIndex, responses.count - 1)]
        callIndex += 1
        return response
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

struct EchoTool: Tool {
    var definition: ToolDefinition { ToolDefinition(name: "echo", description: "", parameters: .object([:])) }
    func run(arguments: JSON) async throws -> String { arguments.objectValue?["text"]?.stringValue ?? "" }
}

struct AgentLoopTests {
    @Test
    func loopRunsToCompletionWithNoToolCalls() async throws {
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, text: "Hello!"), finishReason: .endTurn, usage: Usage(inputTokens: 5, outputTokens: 3)),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry())
        var events: [AgentEvent] = []
        for try await event in loop.run(prompt: "hi") { events.append(event) }
        let result = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first
        #expect(result?.isSuccess == true)
        #expect(result?.text == "Hello!")
        #expect(result?.usage.total == 8)
    }

    @Test
    func loopExecutesToolCallsThenFinishes() async throws {
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, content: [.toolCall(ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("ping")])))]), finishReason: .toolUse),
            ModelResponse(message: Message(role: .assistant, text: "pong"), finishReason: .endTurn),
        ])
    }
}
