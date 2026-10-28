import AgentCore
@testable import AgentGateway
import AgentJournal
@testable import AgentLoop
import Foundation
import Testing

/// Keeps entries in memory, each passed through the line format, so these
/// tests also check that what the loop records survives encoding.
final class MemoryJournal: SessionJournal, @unchecked Sendable {
    let origin = JournalOrigin(mode: "library", nawaVersion: "test")
    private let lock = NSLock()
    private var lines: [Data] = []

    func record(_ entry: JournalEntry) {
        lock.lock(); defer { lock.unlock() }
        // A record that can't be encoded must fail the test, not vanish.
        lines.append(try! JournalFormat.encode(entry, seq: lines.count + 1))
    }

    var contents: JournalContents {
        lock.lock(); defer { lock.unlock() }
        let file = lines.reduce(into: Data()) { file, line in
            file.append(line)
            file.append(UInt8(ascii: "\n"))
        }
        return JournalReader.parse(file)
    }

    var records: [JournalRecord] { contents.entries.map(\.record) }
}

/// Fails every call, like a provider that is down.
struct FailingModel: LanguageModel {
    let providerName = "failing"
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        throw GatewayError.network("offline")
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }
    func listModels() async throws -> [ModelSummary] { [] }
}

func runToEnd(_ loop: AgentLoop, _ prompt: String, continuing: Bool = false) async throws -> AgentResult? {
    var result: AgentResult?
    for try await event in loop.run(prompt: prompt, continuing: continuing) {
        if case .result(let finished) = event { result = finished }
    }
    return result
}

func echoCall(_ id: String, _ text: String) -> ToolCall {
    ToolCall(id: id, name: "echo", arguments: .object(["text": .string(text)]))
}

struct JournalTests {
    /// The journal's main promise: every request can be rebuilt exactly,
    /// also after old tool results were cleared and the context compacted.
    @Test
    func everyRequestCanBeRebuiltFromTheJournal() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(echoCall("c1", "a"), usage: Usage(inputTokens: 10)),
            toolCallResponse(echoCall("c2", "b"), usage: Usage(inputTokens: 10)),
            // Big enough to trigger the compaction before the next turn.
            toolCallResponse(echoCall("c3", "c"), usage: Usage(inputTokens: 600)),
            ModelResponse(message: Message(role: .assistant, text: "Summary: echoed a, b, c."), finishReason: .endTurn),
            ModelResponse(message: Message(role: .assistant, text: "Done."), finishReason: .endTurn),
        ])
        let journal = MemoryJournal()
        let options = LoopOptions(
            keepToolResults: 1,
            compaction: Compaction(atContextTokens: 500, keepRecentMessages: 2),
            streamReplies: false
        )
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), systemPrompt: "Be brief.", options: options, journal: journal)

        let result = try await runToEnd(loop, "Echo three times.")
        #expect(result?.kind == .success)

        let contents = journal.contents
        let calls = contents.modelCalls
        #expect(calls.map(\.purpose) == [.turn, .turn, .turn, .compaction, .turn])
        #expect(calls.count == model.requests.count)
        for (call, sent) in zip(calls, model.requests) {
            let rebuilt = try #require(contents.request(of: call))
            #expect(rebuilt.messages == sent.messages)
            #expect(rebuilt.tools == sent.tools)
        }

        let reasons = contents.entries.compactMap { entry -> ContextRewrite.Reason? in
            if case .contextRewrite(let rewrite) = entry.record { return rewrite.reason }
            return nil
        }
        #expect(reasons == [.toolResultsCleared, .compaction])
        // Replaying the journal leaves the context the loop has now.
        #expect(contents.context(ofSession: loop.session.id) == loop.session.messages)
    }

    @Test
    func aRunIsBracketedAndItsToolRunsTimed() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(echoCall("c1", "hello"), usage: Usage(inputTokens: 5, outputTokens: 2)),
            ModelResponse(message: Message(role: .assistant, text: "Said hello."), finishReason: .endTurn),
        ])
        let journal = MemoryJournal()
        let options = LoopOptions(pricing: Pricing(inputPer1K: 1, outputPer1K: 2), streamReplies: false)
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), options: options, cwd: "/work", journal: journal)
        _ = try await runToEnd(loop, "Say hello.")

        let records = journal.records
        guard case .sessionStarted(let start) = records.first else {
            Issue.record("the first record is not session_started")
            return
        }
        #expect(start.origin.mode == "library")
        #expect(start.cwd == "/work")
        #expect(start.parent == nil)
        guard case .runFinished(let finished) = records.last else {
            Issue.record("the last record is not run_finished")
            return
        }
        #expect(finished.kind == .success)

        let runs = records.compactMap { record -> ToolRunRecord? in
            if case .toolRun(let run) = record { return run }
            return nil
        }
        #expect(runs.map(\.callID) == ["c1"])
        #expect(runs.first?.outputChars == "hello".count)

        let firstCall = try #require(journal.contents.modelCalls.first)
        // 5 input tokens at $1/1K plus 2 output tokens at $2/1K.
        #expect(abs((firstCall.costUSD ?? 0) - 0.009) < 1e-12)
        #expect(firstCall.request.streamed == false)
        #expect(firstCall.firstChunkMS == nil)
    }

    /// One tool set per session in the journal, however many calls send it.
    @Test
    func unchangedToolsAreRecordedOnce() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(echoCall("c1", "a")),
            toolCallResponse(echoCall("c2", "b")),
            ModelResponse(message: Message(role: .assistant, text: "Done."), finishReason: .endTurn),
        ])
        let journal = MemoryJournal()
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), options: LoopOptions(streamReplies: false), journal: journal)
        _ = try await runToEnd(loop, "Go.")

        let toolRecords = journal.records.filter { if case .tools = $0 { return true }; return false }
        #expect(toolRecords.count == 1)
        #expect(Set(journal.contents.modelCalls.map(\.request.toolsID)).count == 1)
    }

    @Test
    func aSubAgentRecordsIntoTheSameJournalUnderItsParent() async throws {
        let model = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "task-1", name: "task", arguments: .object(["prompt": .string("Find it.")]))),
            ModelResponse(message: Message(role: .assistant, text: "Found it."), finishReason: .endTurn),
            ModelResponse(message: Message(role: .assistant, text: "It was found."), finishReason: .endTurn),
        ])
        let journal = MemoryJournal()
        let options = LoopOptions(subAgents: true, helperModel: "small", streamReplies: false)
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: options, journal: journal)
        _ = try await runToEnd(loop, "Look for it.")

        let starts = journal.contents.entries.compactMap { entry -> (session: String, start: SessionStart)? in
            if case .sessionStarted(let start) = entry.record { return (entry.session, start) }
            return nil
        }
        #expect(starts.count == 2)
        let child = try #require(starts.last)
        #expect(child.start.parent == JournalParent(session: loop.session.id, callID: "task-1"))
        #expect(child.start.model == "small")
        #expect(child.session != loop.session.id)

        let childCalls = journal.contents.entries.filter { entry in
            if case .modelCall = entry.record { return entry.session == child.session }
            return false
        }
        #expect(childCalls.count == 1)
    }

    @Test
    func aDeclinedReplyIsKeptOutsideTheContext() async throws {
        let declined = ModelResponse(message: Message(role: .assistant, text: "I can't help."), finishReason: .refusal, model: "big")
        let answer = ModelResponse(message: Message(role: .assistant, text: "Here you go."), finishReason: .endTurn, model: "small")
        let model = ScriptedModel(responses: [declined, answer])
        let journal = MemoryJournal()
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(streamReplies: false, fallbackModel: "small"), journal: journal)
        _ = try await runToEnd(loop, "Help.")

        let records = journal.records
        #expect(records.contains(.message(declined.message, appendedToContext: false)))
        #expect(records.contains(.modelChanged(from: nil, to: "small")))
        #expect(records.contains { if case .refusal(let notice) = $0 { return notice.answeredBy == "small" }; return false })
        #expect(journal.contents.context(ofSession: loop.session.id) == loop.session.messages)
    }

    @Test
    func aFailedCallIsRecordedWithItsError() async throws {
        let journal = MemoryJournal()
        let loop = AgentLoop(gateway: FailingModel(), tools: ToolRegistry(), options: LoopOptions(streamReplies: false), journal: journal)
        let result = try await runToEnd(loop, "Hello?")
        #expect(result?.kind == .errorDuringExecution)

        let call = try #require(journal.contents.modelCalls.first)
        #expect(call.response == nil)
        #expect(call.error?.contains("offline") == true)
    }

    @Test
    func removingADeclinedPromptIsARewrite() async throws {
        let declined = ModelResponse(message: Message(role: .assistant, text: "No."), finishReason: .refusal)
        let journal = MemoryJournal()
        let loop = AgentLoop(gateway: ScriptedModel(responses: [declined]), tools: ToolRegistry(), options: LoopOptions(streamReplies: false), journal: journal)
        let result = try await runToEnd(loop, "Something odd.")
        #expect(result?.kind == .refused)
        #expect(loop.removeDeclinedRequest())

        let rewrite = journal.records.compactMap { record -> ContextRewrite? in
            if case .contextRewrite(let rewrite) = record { return rewrite }
            return nil
        }.last
        #expect(rewrite?.reason == .declinedPromptRemoved)
        #expect(journal.contents.context(ofSession: loop.session.id) == loop.session.messages)
    }

    @Test
    func aLoopWithoutAJournalRecordsNothing() async throws {
        // Nothing to observe but that it runs: the journal is optional.
        let model = ScriptedModel(responses: [ModelResponse(message: Message(role: .assistant, text: "Hi."), finishReason: .endTurn)])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry(), options: LoopOptions(streamReplies: false))
        #expect(try await runToEnd(loop, "Hi")?.kind == .success)
    }
}
