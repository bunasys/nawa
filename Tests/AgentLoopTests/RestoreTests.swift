import AgentCore
@testable import AgentGateway
import AgentJournal
@testable import AgentLoop
import Foundation
import Testing

/// `AgentLoop(restoring:)` with state from `JournalContents.replay`: a
/// session picked up from its journal goes on as if it had never stopped.
struct RestoreTests {
    static let options = LoopOptions(
        pricing: Pricing(inputPer1K: 0.003, outputPer1K: 0.015),
        keepToolResults: 1,
        compaction: Compaction(atContextTokens: 500, keepRecentMessages: 2),
        subAgents: true,
        helperModel: "small",
        helperPricing: Pricing(inputPer1K: 0.001, outputPer1K: 0.005),
        streamReplies: false
    )

    /// Tool calls, a note, a sub-agent, cleared results and a compaction.
    static func firstRunScript() -> [ModelResponse] {
        [
            toolCallResponse(echoCall("c1", "a"), usage: Usage(inputTokens: 10, outputTokens: 2)),
            toolCallResponse(
                ToolCall(id: "n1", name: "remember", arguments: .object(["note": .string("echo works")])),
                usage: Usage(inputTokens: 20, outputTokens: 2)
            ),
            toolCallResponse(
                ToolCall(id: "t1", name: "task", arguments: .object(["prompt": .string("Echo b.")])),
                usage: Usage(inputTokens: 30, outputTokens: 2)
            ),
            // The sub-agent's one call.
            ModelResponse(message: Message(role: .assistant, text: "b"), finishReason: .endTurn, usage: Usage(inputTokens: 7, outputTokens: 1)),
            // Big enough to trigger the compaction before the next turn.
            toolCallResponse(echoCall("c2", "c"), usage: Usage(inputTokens: 600, outputTokens: 2)),
            ModelResponse(message: Message(role: .assistant, text: "Summary: echoed a, b, c."), finishReason: .endTurn, usage: Usage(inputTokens: 50, outputTokens: 9)),
            ModelResponse(message: Message(role: .assistant, text: "Done."), finishReason: .endTurn, usage: Usage(inputTokens: 40, outputTokens: 1)),
        ]
    }

    @Test
    func aRestoredLoopGoesOnExactlyWhereTheOriginalStopped() async throws {
        let againReply = ModelResponse(message: Message(role: .assistant, text: "Again."), finishReason: .endTurn)
        let originalModel = ScriptedModel(responses: Self.firstRunScript() + [againReply])
        let journal = MemoryJournal()
        let tools = ToolRegistry([EchoTool()])
        let original = AgentLoop(gateway: originalModel, tools: tools, systemPrompt: "Be brief.", options: Self.options, journal: journal)
        #expect(try await runToEnd(original, "Echo three times.")?.kind == .success)
        #expect(originalModel.requests.contains { $0.messages.first?.text == ContextShrinking.summarizerInstructions })

        let state = try #require(journal.contents.replay())
        #expect(state.sessionID == original.session.id)
        #expect(state.notes == ["echo works"])

        let restoredModel = ScriptedModel(responses: [againReply])
        let restored = AgentLoop(restoring: state, gateway: restoredModel, tools: tools, systemPrompt: "Be brief.", options: Self.options, journal: journal)
        #expect(restored.session.id == original.session.id)
        #expect(restored.session.messages == original.session.messages)
        #expect(restored.usage == original.usage)
        #expect(restored.totalCost == original.totalCost)
        #expect(restored.model == original.model)

        // The restored loop appends to the same journal without recording
        // the old messages again.
        #expect(try await runToEnd(restored, "Once more.", continuing: true)?.kind == .success)
        let contents = journal.contents
        #expect(contents.context(ofSession: restored.session.id) == restored.session.messages)
        let resumedStarts = contents.entries.filter { entry in
            if case .sessionStarted(let start) = entry.record { return start.resumed }
            return false
        }
        #expect(resumedStarts.count == 1)

        // The original, asked the same, sends the same request.
        #expect(try await runToEnd(original, "Once more.", continuing: true)?.kind == .success)
        let fromOriginal = try #require(originalModel.requests.last)
        let fromRestored = try #require(restoredModel.requests.last)
        // Each loop makes its own prompt message, so only the ids differ.
        #expect(fromRestored.messages.dropLast() == fromOriginal.messages.dropLast())
        #expect(fromRestored.messages.last?.text == fromOriginal.messages.last?.text)
        #expect(fromRestored.tools == fromOriginal.tools)
        #expect(fromRestored.model == fromOriginal.model)
    }

    @Test
    func theModelSwitchedToIsRestored() async throws {
        let reply = ModelResponse(message: Message(role: .assistant, text: "ok"), finishReason: .endTurn)
        let journal = MemoryJournal()
        let loop = AgentLoop(gateway: ScriptedModel(responses: [reply]), tools: ToolRegistry(), options: LoopOptions(streamReplies: false), journal: journal)
        loop.model = "first"
        _ = try await runToEnd(loop, "Hi")
        loop.model = "second"

        let state = try #require(journal.contents.replay())
        #expect(state.model == "second")
    }

    @Test
    func aJournalWithoutASessionReplaysToNothing() {
        #expect(JournalContents(lines: []).replay() == nil)
    }
}
