import AgentCore
@testable import AgentGateway
@testable import AgentLoop
import Foundation
import Synchronization
import Testing

/// Opens once; everyone waiting, and everyone who comes later, goes on.
final class Latch: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Ignores cancellation, like a shell command that keeps running.
    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }
}

/// A tool that runs until the test releases it, whether or not its run was
/// cancelled meanwhile.
struct GatedTool: Tool {
    let started = Latch()
    let release = Latch()
    var definition: ToolDefinition { ToolDefinition(name: "gated", description: "", parameters: .object([:])) }
    func run(arguments: JSON) async throws -> String {
        started.open()
        await release.wait()
        return "edited"
    }
}

/// Holds its first call until released, then answers it like the script.
final class PausingModel: LanguageModel, @unchecked Sendable {
    let providerName = "pausing"
    let script: ScriptedModel
    let called = Latch()
    let release = Latch()

    init(script: ScriptedModel) { self.script = script }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        if script.callIndex == 0 {
            called.open()
            await release.wait()
        }
        return try await script.complete(request)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

private func nonSystemTexts(_ loop: AgentLoop) -> [String] {
    loop.session.messages.filter { $0.role != .system }.map { message in
        let results = message.content.compactMap { block -> String? in
            if case .toolResult(let result) = block { return result.content }
            return nil
        }
        return results.isEmpty ? message.text : results.joined()
    }
}

/// What happens when a run is interrupted and the next one starts.
struct RunLifecycleTests {
    /// The repl's Esc then a queued prompt: the interrupted run's tool is
    /// still going. The next run waits for it, and its result stays (the
    /// edit happened), while the call that never started is answered.
    @Test(.timeLimit(.minutes(1)))
    func aNewRunWaitsForTheInterruptedOneAndKeepsWhatItsToolsDid() async throws {
        let gate = GatedTool()
        let echo = ToolCall(id: "c2", name: "echo", arguments: .object(["text": .string("never")]))
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, content: [.toolCall(ToolCall(id: "c1", name: "gated")), .toolCall(echo)]), finishReason: .toolUse),
            ModelResponse(message: Message(role: .assistant, text: "answer"), finishReason: .endTurn),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([gate, EchoTool()]), options: LoopOptions(streamReplies: false))

        let first = Task { for try await _ in loop.run(prompt: "first") {} }
        await gate.started.wait()
        first.cancel()
        let second = Task { try await finalResult(loop.run(prompt: "second", continuing: true)) }
        // Long enough for a run that doesn't wait to add its prompt.
        try await Task.sleep(for: .milliseconds(50))
        gate.release.open()
        let result = try await second.value

        #expect(result.text == "answer")
        #expect(nonSystemTexts(loop) == ["first", "", "edited", "interrupted by the user before it finished", "second", "answer"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aReplyArrivingAfterAnInterruptIsDropped() async throws {
        let tool = CountingTool()
        let script = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "c1", name: "count")),
            ModelResponse(message: Message(role: .assistant, text: "ok"), finishReason: .endTurn),
        ])
        let model = PausingModel(script: script)
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([tool]), options: LoopOptions(streamReplies: false))

        let first = Task { for try await _ in loop.run(prompt: "first") {} }
        await model.called.wait()
        first.cancel()
        model.release.open()
        _ = try await finalResult(loop.run(prompt: "second", continuing: true))

        #expect(tool.calls == 0)
        #expect(nonSystemTexts(loop) == ["first", "second", "ok"])
    }

    /// `onEvent` and the stream see the same events, stop notes included.
    @Test
    func onEventGetsWhatTheStreamYields() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("x")]))
        let model = ScriptedModel(responses: [toolCallResponse(call)])
        let hooked = Mutex<[String]>([])
        let loop = AgentLoop(
            gateway: model, tools: ToolRegistry([EchoTool()]), options: LoopOptions(maxTurns: 1, streamReplies: false),
            onEvent: { event in hooked.withLock { $0.append(kind(event)) } }
        )

        var streamed: [String] = []
        for try await event in loop.run(prompt: "go") { streamed.append(kind(event)) }

        #expect(streamed == ["init", "assistant", "toolResults", "informational", "result"])
        #expect(hooked.withLock { $0 } == streamed)
    }

    /// `/config set` can turn the loop check on while a run goes on.
    @Test
    func theLoopCheckReadsTheCurrentOptions() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("same")]))
        let model = ScriptedModel(responses: [toolCallResponse(call)])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), options: LoopOptions(maxTurns: 10, loopCheckAfterTurns: nil))
        model.onCall = { index in
            if index == 0 { loop.options.loopCheckAfterTurns = 3 }
        }

        let result = try await finalResult(loop.run(prompt: "go"))

        #expect(result.kind == .errorDuringExecution)
        #expect(result.numTurns == 3)
    }
}

struct BudgetTests {
    let options = LoopOptions(maxBudgetUSD: 1, pricing: Pricing(inputPer1K: 1), streamReplies: false)

    /// The answer that crossed the cap was paid for, so it is kept; the
    /// next prompt stops without paying for a call it would throw away.
    @Test
    func aSpentBudgetStopsTheNextPromptBeforeItsModelCall() async throws {
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, text: "expensive answer"), finishReason: .endTurn, usage: Usage(inputTokens: 1500)),
            ModelResponse(message: Message(role: .assistant, text: "never asked")),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: options)

        let first = try await finalResult(loop.run(prompt: "one"))
        let second = try await finalResult(loop.run(prompt: "two", continuing: true))

        #expect(first.kind == .success)
        #expect(first.text == "expensive answer")
        #expect(second.kind == .errorMaxBudgetUSD)
        #expect(model.requests.count == 1)
    }

    @Test
    func toolCallsInAReplyThatCrossesTheCapDontRun() async throws {
        let tool = CountingTool()
        let model = ScriptedModel(responses: [toolCallResponse(ToolCall(id: "c1", name: "count"), usage: Usage(inputTokens: 1500))])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([tool]), options: options)

        let result = try await finalResult(loop.run(prompt: "go"))

        #expect(result.kind == .errorMaxBudgetUSD)
        #expect(tool.calls == 0)
    }
}

struct UnusableArgumentsTests {
    private func toolResults(_ loop: AgentLoop) -> [ToolCallResult] {
        loop.session.messages.flatMap(\.content).compactMap { block in
            if case .toolResult(let result) = block { return result }
            return nil
        }
    }

    /// A reply cut off at max_tokens ends inside its last call; the calls
    /// before it are whole and run.
    @Test
    func theCallCutOffAtMaxTokensIsNotRun() async throws {
        let tool = CountingTool()
        let calls: [ContentBlock] = [.toolCall(ToolCall(id: "c1", name: "count")), .toolCall(ToolCall(id: "c2", name: "count", arguments: .object(["path": .string("a.sw")])))]
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, content: calls), finishReason: .maxTokens),
            ModelResponse(message: Message(role: .assistant, text: "done"), finishReason: .endTurn),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([tool]), options: LoopOptions(streamReplies: false))

        _ = try await finalResult(loop.run(prompt: "go"))

        #expect(tool.calls == 1)
        let results = toolResults(loop)
        #expect(results.map(\.isError) == [false, true])
        #expect(results[1].content.contains("max_tokens"))
    }

    @Test
    func argumentsThatAreNotAJSONObjectAreNotRun() async throws {
        let tool = CountingTool()
        let broken = ToolCall(id: "c1", name: "count", arguments: .string(#"{"path": "a.sw"#))
        let empty = ToolCall(id: "c2", name: "count", arguments: .string(""))
        let model = ScriptedModel(responses: [
            ModelResponse(message: Message(role: .assistant, content: [.toolCall(broken), .toolCall(empty)]), finishReason: .toolUse),
            ModelResponse(message: Message(role: .assistant, text: "done"), finishReason: .endTurn),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([tool]), options: LoopOptions(streamReplies: false))

        _ = try await finalResult(loop.run(prompt: "go"))

        // A call without arguments still runs.
        #expect(tool.calls == 1)
        let results = toolResults(loop)
        #expect(results[0].isError)
        #expect(results[0].content.contains("not valid JSON"))
        #expect(!results[1].isError)
    }
}
