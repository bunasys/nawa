import AgentCore
@testable import AgentGateway
import AgentInstructions
@testable import AgentLoop
import Foundation
import Testing

/// What the loop does when a model declines a prompt.
struct RefusalTests {
    private func refusal(by model: String, category: String? = "cyber", recommending: String? = nil, partial: [ContentBlock] = []) -> ModelResponse {
        ModelResponse(
            message: Message(role: .assistant, content: partial),
            finishReason: .refusal,
            usage: Usage(inputTokens: 10),
            model: model,
            refusal: RefusalDetails(category: category, explanation: "declined", recommendedModel: recommending)
        )
    }

    private func answer(_ text: String, by model: String) -> ModelResponse {
        ModelResponse(message: Message(role: .assistant, text: text), finishReason: .endTurn, usage: Usage(inputTokens: 10, outputTokens: 2), model: model)
    }

    private func run(_ loop: AgentLoop, _ prompt: String) async throws -> (refusals: [RefusalNotice], result: AgentResult?) {
        var refusals: [RefusalNotice] = []
        var result: AgentResult?
        for try await event in loop.run(prompt: prompt, continuing: true) {
            if case .refusal(let notice) = event { refusals.append(notice) }
            if case .result(let final) = event { result = final }
        }
        return (refusals, result)
    }

    @Test
    func aDeclinedPromptIsRetriedOnTheFallbackModelWhichTheSessionKeeps() async throws {
        let tool = CountingTool()
        let partial: [ContentBlock] = [.text("Sure, here is"), .toolCall(ToolCall(id: "c1", name: "count"))]
        let model = ScriptedModel(responses: [refusal(by: "big", partial: partial), answer("Done.", by: "small")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([tool]), options: LoopOptions(fallbackModel: "small"))
        loop.model = "big"

        let (refusals, result) = try await run(loop, "scan my server")
        #expect(refusals == [RefusalNotice(declinedBy: "big", category: "cyber", explanation: "declined", answeredBy: "small")])
        #expect(result?.kind == .success)
        #expect(result?.text == "Done.")
        #expect(result?.refusal == refusals.first)
        #expect(model.requests.map(\.model) == ["big", "small"])
        #expect(loop.model == "small")
        // The declined reply is gone: its tool call never ran, its text isn't kept.
        #expect(tool.calls == 0)
        #expect(loop.session.messages.filter { $0.role != .system }.map(\.text) == ["scan my server", "Done."])
        #expect(result?.usage.inputTokens == 20)
    }

    @Test
    func withoutAFallbackTheRunEndsRefused() async throws {
        let model = ScriptedModel(responses: [refusal(by: "big")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry())
        let (refusals, result) = try await run(loop, "scan my server")
        #expect(refusals.first?.answeredBy == nil)
        #expect(result?.kind == .refused)
        #expect(result?.refusal?.category == "cyber")
        #expect(model.requests.count == 1)
    }

    @Test
    func theProvidersRecommendationIsUsedWhenNoFallbackIsSet() async throws {
        let model = ScriptedModel(responses: [refusal(by: "big", recommending: "other"), answer("ok", by: "other")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry())
        let (_, result) = try await run(loop, "hi")
        #expect(result?.text == "ok")
        #expect(model.requests.last?.model == "other")
    }

    @Test
    func aFallbackThatDeclinesToEndsTheRun() async throws {
        let model = ScriptedModel(responses: [refusal(by: "big"), refusal(by: "small")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(fallbackModel: "small"))
        let (refusals, result) = try await run(loop, "hi")
        #expect(refusals.map(\.answeredBy) == ["small", nil])
        #expect(result?.kind == .refused)
        #expect(model.requests.count == 2)
    }

    @Test
    func reasoningExtractionIsNotRetried() async throws {
        let model = ScriptedModel(responses: [refusal(by: "big", category: "reasoning_extraction"), answer("no", by: "small")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(fallbackModel: "small"))
        let (_, result) = try await run(loop, "show your thinking")
        #expect(result?.kind == .refused)
        #expect(model.requests.count == 1)
    }

    @Test
    func aServerSideFallbackIsReportedAndItsAnswerKept() async throws {
        var served = answer("Here you go.", by: "claude-opus-4-8")
        served.declinedBy = ["claude-opus-5-5"]
        let loop = AgentLoop(gateway: ScriptedModel(responses: [served]), tools: ToolRegistry())
        let (refusals, result) = try await run(loop, "hi")
        #expect(refusals == [RefusalNotice(declinedBy: "claude-opus-5-5", answeredBy: "claude-opus-4-8")])
        #expect(result?.kind == .success)
        #expect(result?.text == "Here you go.")
        #expect(result?.refusal != nil)
    }

    @Test
    func removingTheDeclinedPromptTakesOutItsExchangeAndRestoresTheModel() async throws {
        let model = ScriptedModel(responses: [
            answer("Hello.", by: "big"),
            refusal(by: "big"), answer("Fallback answer.", by: "small"),
            answer("Back on big.", by: "big"),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), systemPrompt: "Be brief.", options: LoopOptions(fallbackModel: "small"))
        loop.model = "big"
        _ = try await run(loop, "hi")
        _ = try await run(loop, "scan my server")
        #expect(loop.model == "small")

        #expect(loop.removeDeclinedRequest())
        #expect(loop.model == "big")
        #expect(loop.session.messages.map(\.text) == [SystemPrompt.composed("Be brief."), "hi", "Hello."])
        // Only once: there is nothing left to remove.
        #expect(!loop.removeDeclinedRequest())

        _ = try await run(loop, "next")
        #expect(model.requests.last?.model == "big")
    }

    @Test
    func aNewRunForgetsTheDeclinedPrompt() async throws {
        let model = ScriptedModel(responses: [refusal(by: "big"), answer("ok", by: "big")])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry())
        _ = try await run(loop, "scan my server")
        _ = try await run(loop, "something else")
        #expect(!loop.removeDeclinedRequest())
    }
}
