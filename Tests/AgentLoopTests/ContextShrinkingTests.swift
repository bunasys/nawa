import AgentCore
import AgentGateway
@testable import AgentLoop
import Foundation
import Testing

/// Tool calls and results as a conversation would hold them.
private func exchange(_ id: String, tool: String = "read_file", arguments: JSON = .object([:]), output: String) -> [Message] {
    [
        Message(role: .assistant, content: [.toolCall(ToolCall(id: id, name: tool, arguments: arguments))]),
        ToolCallResult(callID: id, name: tool, content: output).asMessage,
    ]
}

private func resultContents(_ messages: [Message]) -> [String] {
    messages.flatMap { message in
        message.content.compactMap { block -> String? in
            if case .toolResult(let result) = block { return result.content }
            return nil
        }
    }
}

struct ToolResultClearingTests {
    @Test
    func sizeLimitClearsOldResultsDownToHalf() {
        let big = String(repeating: "x", count: 400)
        let messages = (0..<6).flatMap { exchange("c\($0)", output: big) }  // 2,400 chars

        // Under the limit: nothing changes.
        #expect(ContextShrinking.clearingOldToolResults(messages, keep: nil, maxChars: 2_400) == messages)

        // Over it: keep the newest results that fit in half (1,000 → 2 results).
        let cleared = ContextShrinking.clearingOldToolResults(messages, keep: nil, maxChars: 2_000)
        let contents = resultContents(cleared)
        #expect(contents.filter { $0 == big }.count == 2)
        #expect(contents.suffix(2) == [big, big])
        #expect(contents.prefix(4).allSatisfy { $0.hasPrefix("[elided to save context:") })
    }

    @Test
    func theNewestResultIsAlwaysKept() {
        let huge = String(repeating: "y", count: 5_000)
        let messages = exchange("c0", output: "small") + exchange("c1", output: huge)

        let contents = resultContents(ContextShrinking.clearingOldToolResults(messages, keep: nil, maxChars: 1_000))

        #expect(contents.last == huge)
        #expect(contents.first?.hasPrefix("[elided") == true)
    }

    @Test
    func clearedResultsSayWhatTheyWere() {
        let messages = exchange("c0", arguments: .object(["path": .string("a.py")]), output: "1\n2\n3")
            + exchange("c1", tool: "shell", output: "ok")
            + exchange("c2", tool: "shell", output: "ok")

        let contents = resultContents(ContextShrinking.clearingOldToolResults(messages, keep: 1))

        #expect(contents[0] == "[elided to save context: read_file {\"path\":\"a.py\"} returned 3 lines; run it again if you need it]")
        #expect(contents[1] == "[elided to save context: shell {} returned 1 line; run it again if you need it]")
        #expect(contents[2] == "ok")
    }

    @Test
    func longArgumentsAreShortenedInTheNote() {
        let arguments = JSON.object(["old_string": .string(String(repeating: "z", count: 500))])
        let note = ContextShrinking.elidedNote(
            for: ToolCallResult(callID: "c", name: "edit_file", content: "boom", isError: true),
            call: ToolCall(id: "c", name: "edit_file", arguments: arguments)
        )
        #expect(note.count < 260)
        #expect(note.hasSuffix("…} failed; run it again if you need it]") || note.contains("… failed;"))
    }

    @Test
    func resultsClearedByOlderVersionsStayCleared() {
        let legacy = ToolCallResult(callID: "old", name: "t", content: ContextShrinking.legacyElidedResult).asMessage
        let messages = [legacy] + exchange("c1", output: "a") + exchange("c2", output: "b")

        // One whole result per kept slot: the legacy marker isn't counted as whole.
        #expect(ContextShrinking.clearingOldToolResults(messages, keep: 1) == messages)
    }
}

struct RepeatedOutputTests {
    let file = String(repeating: "line of code\n", count: 100)

    @Test
    func aRepeatedResultPointsToTheEarlierOne() {
        let context = exchange("c1", output: file)
        let again = ToolCallResult(callID: "c2", name: "read_file", content: file)

        let deduped = ContextShrinking.dedupingRepeatedResults([again], against: context)

        #expect(deduped[0].content.hasPrefix("[same output as the earlier read_file call c1"))
        #expect(deduped[0].callID == "c2")
    }

    @Test
    func smallErrorAndClearedResultsAreLeftAlone() {
        let context = exchange("c1", output: "short") + [
            ToolCallResult(callID: "c2", name: "t", content: ContextShrinking.elidedNote(
                for: ToolCallResult(callID: "c2", name: "t", content: file), call: nil
            )).asMessage,
        ]
        let short = ToolCallResult(callID: "c3", name: "t", content: "short")
        let failed = ToolCallResult(callID: "c4", name: "t", content: file, isError: true)
        let afterClearing = ToolCallResult(callID: "c5", name: "t", content: file)

        let deduped = ContextShrinking.dedupingRepeatedResults([short, failed, afterClearing], against: context)

        #expect(deduped == [short, failed, afterClearing])
    }

    @Test
    func repeatsWithinOneTurnPointToTheFirst() {
        let first = ToolCallResult(callID: "a", name: "read_file", content: file)
        let second = ToolCallResult(callID: "b", name: "read_file", content: file)

        let deduped = ContextShrinking.dedupingRepeatedResults([first, second], against: [])

        #expect(deduped[0] == first)
        #expect(deduped[1].content.contains("call a"))
    }

    /// The model's context gets the pointer; the event stream keeps the real output.
    @Test
    func theLoopSendsThePointerButReportsTheRealResult() async throws {
        let text = String(repeating: "same output\n", count: 60)
        let first = ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string(text)]))
        let second = ToolCall(id: "c2", name: "echo", arguments: .object(["text": .string(text)]))
        let model = ScriptedModel(responses: [
            toolCallResponse(first),
            toolCallResponse(second),
            ModelResponse(message: Message(role: .assistant, text: "done")),
        ])
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]))

        var reported: [ToolCallResult] = []
        for try await event in loop.run(prompt: "go") {
            if case .toolResults(let batch) = event { reported += batch }
        }

        #expect(reported.map(\.content) == [text, text])
        let sent = resultContents(model.requests.last?.messages ?? [])
        #expect(sent.first == text)
        #expect(sent.last?.hasPrefix("[same output as the earlier echo call c1") == true)
    }
}

struct CompactionSummaryTests {
    @Test
    func fileListsComeFromToolCallsAndTheEarlierSummary() {
        let earlier = ContextShrinking.summaryText(
            "old notes",
            notes: [],
            files: (read: ["a.py", "b.py"], changed: ["a.py"])
        )
        let messages = [Message(role: .user, text: earlier)]
            + exchange("c1", arguments: .object(["path": .string("c.py")]), output: "x")
            + exchange("c2", tool: "edit_file", arguments: .object(["path": .string("b.py")]), output: "ok")
            + exchange("c3", arguments: .object(["path": .string("a.py")]), output: "x")

        let files = ContextShrinking.fileLists(in: messages)

        // Each path once, at its newest position.
        #expect(files.read == ["b.py", "c.py", "a.py"])
        #expect(files.changed == ["a.py", "b.py"])
    }

    @Test
    func summaryCarriesNotesAndFilesAfterTheModelsText() {
        let text = ContextShrinking.summaryText("## Goal\nFix it.", notes: ["tests in Tests/"], files: (read: ["a.py"], changed: []))

        #expect(text.hasPrefix(ContextShrinking.summaryHeader + "\n\n## Goal\nFix it."))
        #expect(text.hasSuffix("- tests in Tests/\n\nFiles read: a.py"))
        #expect(!text.contains("Files changed"))
    }

    @Test
    func listsKeepTheNewestPaths() {
        let messages = (0..<100).flatMap { exchange("c\($0)", arguments: .object(["path": .string("f\($0)")]), output: "x") }

        let read = ContextShrinking.fileLists(in: messages).read

        #expect(read.count == ContextShrinking.maxListedFiles)
        #expect(read.last == "f99")
    }
}

/// Rejects requests for one model, like a provider that doesn't serve it;
/// answers the rest from a script.
private final class RejectsOneModel: LanguageModel, @unchecked Sendable {
    let providerName = "rejecting"
    let rejected: String
    let script: ScriptedModel
    var requestedModels: [String?] = []

    init(rejecting rejected: String, script: ScriptedModel) {
        self.rejected = rejected
        self.script = script
    }

    struct UnknownModel: Error {}

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requestedModels.append(request.model)
        if request.model == rejected { throw UnknownModel() }
        return try await script.complete(request)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        completeAsStream(request)
    }

    func listModels() async throws -> [ModelSummary] { [] }
}

struct HelperModelFallbackTests {
    /// A helper model nobody serves must not end the run: the summary is
    /// made by the session's model instead, and the events say so.
    @Test
    func aHelperModelThatFailsFallsBackToTheSessionsModel() async throws {
        let script = ScriptedModel(responses: [
            toolCallResponse(ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("x")])), usage: Usage(inputTokens: 50)),
            toolCallResponse(ToolCall(id: "c2", name: "echo", arguments: .object(["text": .string("y")])), usage: Usage(inputTokens: 500)),
            ModelResponse(message: Message(role: .assistant, text: "SUMMARY")),
            ModelResponse(message: Message(role: .assistant, text: "done")),
        ])
        let model = RejectsOneModel(rejecting: "typo-model", script: script)
        let options = LoopOptions(compaction: Compaction(atContextTokens: 400, keepRecentMessages: 2), helperModel: "typo-model")
        let loop = AgentLoop(gateway: model, tools: ToolRegistry([EchoTool()]), options: options)
        loop.model = "main"

        var notes: [String] = []
        var final: AgentResult?
        for try await event in loop.run(prompt: "go") {
            if case .informational(let text) = event { notes.append(text) }
            if case .result(let result) = event { final = result }
        }

        #expect(final?.text == "done")
        #expect(model.requestedModels == ["main", "main", "typo-model", "main", "main"])
        #expect(notes.first?.hasPrefix("The helper model typo-model couldn't summarize") == true)
        #expect(loop.session.messages.contains { $0.text.contains("SUMMARY") })
    }
}
