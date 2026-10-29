import AgentCore
import AgentGateway
import AgentInstructions
@testable import AgentLoop
import Foundation
import Synchronization
import Testing

/// Answers sub-agents by their job, from any number of tasks at once, and
/// remembers how many calls were in flight together.
final class ParallelModel: LanguageModel, Sendable {
    let providerName = "parallel"
    let parentReplies: Mutex<[ModelResponse]>
    let inFlight = Mutex(0)
    let mostInFlight = Mutex(0)
    let childInputTokens: Int

    init(parentReplies: [ModelResponse], childInputTokens: Int = 10) {
        self.parentReplies = Mutex(parentReplies)
        self.childInputTokens = childInputTokens
    }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let firstText = request.messages.first { $0.role == .user }?.text ?? ""
        guard firstText.hasPrefix(AgentLoop.subAgentBrief) else {
            return parentReplies.withLock { $0.removeFirst() }
        }
        let now = inFlight.withLock { count in count += 1; return count }
        mostInFlight.withLock { $0 = max($0, now) }
        // Long enough that children started together overlap.
        try await Task.sleep(for: .milliseconds(100))
        inFlight.withLock { $0 -= 1 }
        let job = firstText.components(separatedBy: "Your job:\n").last ?? ""
        return ModelResponse(message: Message(role: .assistant, text: "answer to \(job)"), usage: Usage(inputTokens: childInputTokens))
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

private func task(_ id: String, _ job: String) -> ToolCall {
    ToolCall(id: id, name: "task", arguments: .object(["prompt": .string(job)]))
}

struct SubAgentTests {
    @Test
    func contextGoesBeforeTheJob() {
        let prompt = AgentLoop.subAgentPrompt(job: "find X", context: "X was renamed to Y in a.swift:12")

        #expect(prompt.hasPrefix(AgentLoop.subAgentBrief))
        #expect(prompt.hasSuffix("What the agent that started you already knows:\nX was renamed to Y in a.swift:12\n\nYour job:\nfind X"))
        #expect(AgentLoop.subAgentPrompt(job: "find X", context: "") == AgentLoop.subAgentBrief + "\n\nYour job:\nfind X")
    }

    @Test
    func longAnswersAreCutToHeadAndTail() {
        let answer = String(repeating: "h", count: 20_000) + String(repeating: "m", count: 10_000) + String(repeating: "t", count: 10_000)

        let capped = AgentLoop.cappedSubAgentAnswer(answer)

        #expect(capped.count < AgentLoop.maxSubAgentAnswerChars + 100)
        #expect(capped.hasPrefix(String(repeating: "h", count: 16_000)))
        #expect(capped.hasSuffix(String(repeating: "t", count: 8_000)))
        #expect(capped.contains("[… 16000 characters of the sub-agent's answer left out …]"))
        #expect(AgentLoop.cappedSubAgentAnswer("short") == "short")
    }

    @Test(.timeLimit(.minutes(1)))
    func severalTasksRunTogetherAndAnswerInCallOrder() async throws {
        let calls = (1...5).map { task("t\($0)", "job \($0)") }
        let model = ParallelModel(parentReplies: [
            ModelResponse(message: Message(role: .assistant, content: calls.map { .toolCall($0) }), finishReason: .toolUse, usage: Usage(inputTokens: 1)),
            ModelResponse(message: Message(role: .assistant, text: "done"), usage: Usage(inputTokens: 1)),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(subAgents: true))

        var forwardedFrom = Set<String>()
        var final: AgentResult?
        for try await event in loop.run(prompt: "go") {
            if case .subAgent(let update) = event { forwardedFrom.insert(update.callID) }
            if case .result(let result) = event { final = result }
        }

        let results = loop.session.messages.filter { $0.role == .tool }.flatMap(\.content).compactMap { block -> ToolCallResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
        #expect(results.map(\.callID) == ["t1", "t2", "t3", "t4", "t5"])
        #expect(results.map(\.content) == (1...5).map { "answer to job \($0)" })
        #expect(model.mostInFlight.withLock { $0 } == AgentLoop.maxParallelSubAgents)
        #expect(forwardedFrom == ["t1", "t2", "t3", "t4", "t5"])
        // Two parent calls plus five children of 10 tokens each.
        #expect(final?.usage.inputTokens == 52)
    }

    @Test(.timeLimit(.minutes(1)))
    func childrenRunningTogetherSplitTheBudget() async throws {
        let model = ParallelModel(
            parentReplies: [
                ModelResponse(message: Message(role: .assistant, content: [.toolCall(task("a", "one")), .toolCall(task("b", "two"))]), finishReason: .toolUse, usage: Usage(inputTokens: 200)),
                ModelResponse(message: Message(role: .assistant, text: "done")),
            ],
            childInputTokens: 500
        )
        // $1 budget, $0.20 spent by the parent: $0.80 left, $0.40 per child.
        // Each child's call costs $0.50: within $0.80, over its $0.40 share.
        let options = LoopOptions(maxBudgetUSD: 1, pricing: Pricing(inputPer1K: 1), subAgents: true)
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: options)

        _ = try await finalResult(loop.run(prompt: "go"))

        let results = loop.session.messages.filter { $0.role == .tool }.flatMap(\.content).compactMap { block -> ToolCallResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.isError && $0.content.contains(AgentResultKind.errorMaxBudgetUSD.rawValue) })
    }
}

struct LiveOptionsTests {
    /// `/config set` replaces the options of a running loop; the next turn uses them.
    @Test
    func changedOptionsApplyFromTheNextModelCall() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("x")]))
        let model = ScriptedModel(responses: [
            toolCallResponse(call),
            ModelResponse(message: Message(role: .assistant, text: "done")),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), options: LoopOptions(maxOutputTokens: 100))
        model.onCall = { index in
            if index == 0 { loop.options.maxOutputTokens = 200 }
        }

        _ = try await finalResult(loop.run(prompt: "go"))

        #expect(model.requests.map(\.maxOutputTokens) == [100, 200])
    }
}

struct LoopSettingsTests {
    @Test
    func settingsReplaceOnlyWhatTheySet() {
        let base = LoopOptions(maxTurns: 50, keepToolResults: nil, compaction: Compaction(atContextTokens: 120_000, keepRecentMessages: 8), streamReplies: false)

        let options = base.applying(LoopSettings(
            compactAt: 600_000,
            helperModel: "small",
            price: TokenPrice(inputPerMillion: 3, outputPerMillion: 15),
            maxBudgetUSD: 2
        ))

        #expect(options.maxTurns == 50)
        #expect(options.compaction?.atContextTokens == 600_000)
        #expect(options.compaction?.keepRecentMessages == 8)
        #expect(options.helperModel == "small")
        #expect(options.pricing == Pricing(inputPer1K: 0.003, outputPer1K: 0.015))
        #expect(options.maxBudgetUSD == 2)
        #expect(options.streamReplies == false)  // not set, so not changed
        #expect(base.applying(LoopSettings()).maxTurns == 50)
    }

    @Test
    func compactAtTurnsCompactionOn() {
        let options = LoopOptions().applying(LoopSettings(compactAt: 200_000))
        #expect(options.compaction?.atContextTokens == 200_000)
    }
}

struct FirstPrinciplesTests {
    /// A program linking Nawa passes its own prompt; Nawa's principles stay
    /// first, for it and for its sub-agents (once, not twice).
    @Test
    func everyRequestStartsWithThePrinciplesThenTheCallersPrompt() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "c1", name: "task", arguments: .object(["prompt": .string("look")]))),
            ModelResponse(message: Message(role: .assistant, text: "found")),
            ModelResponse(message: Message(role: .assistant, text: "done")),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), systemPrompt: "You review code.", options: LoopOptions(subAgents: true))

        _ = try await finalResult(loop.run(prompt: "review"))

        let expected = SystemPrompt.composed("You review code.")
        #expect(model.requests.allSatisfy { $0.messages.first?.text == expected })
        #expect(model.requests.allSatisfy { $0.messages.filter { $0.role == .system }.count == 1 })
    }
}
