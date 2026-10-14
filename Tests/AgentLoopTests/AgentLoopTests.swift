import AgentCore
@testable import AgentGateway
@testable import AgentLoop
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
    /// Every request received, in order. Calls are sequential, so no lock.
    var requests: [ModelRequest] = []

    init(responses: [ModelResponse]) {
        self.responses = responses
    }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requests.append(request)
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

    @Test
    func subAgentAnswersAndItsUsageCountsInTheParent() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "c1", name: "task", arguments: .object(["prompt": .string("find X")])), usage: Usage(inputTokens: 10)),
            ModelResponse(message: Message(role: .assistant, text: "X is in a.swift"), usage: Usage(inputTokens: 100)),
            ModelResponse(message: Message(role: .assistant, text: "done"), usage: Usage(inputTokens: 1)),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(subAgents: true, helperModel: "small"))
        loop.model = "big"
        let result = try await finalResult(loop.run(prompt: "where is X?"))

        #expect(result.text == "done")
        #expect(result.usage.inputTokens == 111)
        #expect(model.requests[1].model == "small")
        #expect(model.requests[1].messages.map(\.text) == ["find X"])
        #expect(loop.session.messages.last { $0.role == .tool }?.content.first == ToolCall.result(ToolCall(id: "c1", name: "task"), content: "X is in a.swift"))
    }

    @Test
    func longConversationIsCompactedAndNotesSurvive() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "c1", name: "remember", arguments: .object(["note": .string("tests live in Tests/")])), usage: Usage(inputTokens: 50)),
            toolCallResponse(ToolCall(id: "c2", name: "echo", arguments: .object(["text": .string("x")])), usage: Usage(inputTokens: 500)),
            ModelResponse(message: Message(role: .assistant, text: "SUMMARY")),
            ModelResponse(message: Message(role: .assistant, text: "done")),
        ])
        let options = LoopOptions(compaction: Compaction(atContextTokens: 400, keepRecentMessages: 2))
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), systemPrompt: "SYS", options: options)
        let result = try await finalResult(loop.run(prompt: "go"))

        #expect(result.text == "done")
        #expect(model.requests[2].tools == nil)
        #expect(model.requests[2].messages.last?.text.contains("tests live in Tests/") == true)
        let messages = loop.session.messages
        #expect(messages[0].text == "SYS")
        #expect(messages[1].text.contains("SUMMARY"))
        #expect(messages[1].text.contains("- tests live in Tests/"))
        // The kept part starts at the assistant's echo call, never at an orphaned tool result.
        #expect(messages[2].toolCalls.first?.id == "c2")
    }

    @Test
    func oldToolResultsAreClearedInBatches() {
        func results(_ count: Int) -> [Message] {
            (0..<count).map { ToolCallResult(callID: "c\($0)", name: "t", content: "output \($0)").asMessage }
        }
        let four = results(4)
        #expect(ContextShrinking.clearingOldToolResults(four, keep: 2) == four)

        let cleared = ContextShrinking.clearingOldToolResults(results(5), keep: 2)
        let contents = cleared.map { $0.content.first.flatMap { if case .toolResult(let r) = $0 { r.content } else { nil } } }
        #expect(contents == [ContextShrinking.elidedResult, ContextShrinking.elidedResult, ContextShrinking.elidedResult, "output 3", "output 4"])
        // Cleared results do not count again, so the next clearing waits for a new batch.
        let oneMore = cleared + results(1)
        #expect(ContextShrinking.clearingOldToolResults(oneMore, keep: 2) == oneMore)
    }

    @Test
    func pricingChargesCacheTokensAtTheirOwnRates() {
        let pricing = Pricing(inputPer1K: 1, outputPer1K: 10)
        let cost = pricing.cost(of: Usage(inputTokens: 1000, outputTokens: 1000, cacheReadTokens: 10_000, cacheWriteTokens: 1000))
        #expect(abs(cost - (1 + 10 + 1 + 1.25)) < 1e-9)
    }
}

func toolCallResponse(_ call: ToolCall, usage: Usage = .zero) -> ModelResponse {
    ModelResponse(message: Message(role: .assistant, content: [.toolCall(call)]), finishReason: .toolUse, usage: usage)
}

func finalResult(_ stream: AsyncThrowingStream<AgentEvent, any Error>) async throws -> AgentResult {
    var final: AgentResult?
    for try await event in stream {
        if case .result(let result) = event { final = result }
    }
    return try #require(final)
}
