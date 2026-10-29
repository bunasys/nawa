import Synchronization
import Testing
import AgentCore
@testable import AgentTUI

@Suite struct KeyDecoderTests {
    private func keys(_ string: String) -> [Key] {
        var decoder = KeyDecoder()
        return decoder.decode(Array(string.utf8))
    }

    @Test func arrowsInBothEncodings() {
        #expect(keys("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D") == [.up, .down, .right, .left])
        #expect(keys("\u{1B}OA\u{1B}OD") == [.up, .left])
    }

    @Test func homeAndEndVariants() {
        #expect(keys("\u{1B}[H\u{1B}[1~\u{1B}OH\u{1B}[7~") == [.home, .home, .home, .home])
        #expect(keys("\u{1B}[F\u{1B}[4~\u{1B}OF\u{1B}[8~") == [.end, .end, .end, .end])
    }

    @Test func ctrlArrowsMoveByWord() {
        #expect(keys("\u{1B}[1;5D\u{1B}[1;5C\u{1B}b\u{1B}f") == [.wordLeft, .wordRight, .wordLeft, .wordRight])
    }

    @Test func enterVariants() {
        #expect(keys("\r") == [.enter])
        #expect(keys("\n") == [.newline])  // Ctrl-J
        #expect(keys("\u{1B}\r") == [.newline])  // Alt-Enter
        #expect(keys("\u{1B}[27;2;13~") == [.newline])  // Shift-Enter, modifyOtherKeys
        #expect(keys("\u{1B}[13;2u") == [.newline])  // Shift-Enter, kitty
        #expect(keys("\u{1B}[13;5u") == [.newline])  // Ctrl-Enter, kitty
        #expect(keys("\u{1B}[13u") == [.enter])
    }

    @Test func controlKeys() {
        #expect(keys("\u{01}\u{03}\u{04}\u{17}") == [.control("a"), .control("c"), .control("d"), .control("w")])
        #expect(keys("\u{7F}\u{1B}[3~\t") == [.backspace, .delete, .tab])
        #expect(keys("\u{1B}[99;5u") == [.control("c")])
    }

    @Test func unknownSequencesAreDroppedNotTyped() {
        #expect(keys("a\u{1B}[5~b\u{1B}[?1;2cc\u{1B}OPd\u{1B}[Z") == [.text("abcd")])
    }

    @Test func loneEscWaitsUntilFlushed() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}".utf8)) == [])
        #expect(decoder.hasPending)
        #expect(decoder.flush() == [.escape])
        #expect(!decoder.hasPending)
        #expect(keys("\u{1B}\u{1B}[A") == [.escape, .up])
    }

    @Test func sequenceSplitAcrossReads() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}[27;2".utf8)) == [])
        #expect(decoder.decode(Array(";13~x".utf8)) == [.newline, .text("x")])
    }

    @Test func utf8CharacterSplitAcrossReads() {
        var decoder = KeyDecoder()
        let bytes = Array("نواة😀".utf8)
        var result: [Key] = []
        for byte in bytes { result += decoder.decode([byte]) }
        #expect(result.map { if case .text(let t) = $0 { t } else { "?" } }.joined() == "نواة😀")
        #expect(!decoder.hasPending)
    }

    @Test func typedRunIsOneTextKey() {
        #expect(keys("héllo") == [.text("héllo")])
    }

    @Test func bracketedPasteKeepsNewlinesAndEscBytes() {
        let pasted = "line one\r\nline\u{1B}[31m two\rthree"
        #expect(keys("\u{1B}[200~\(pasted)\u{1B}[201~x") == [.paste("line one\nline\u{1B}[31m two\nthree"), .text("x")])
    }

    @Test func bracketedPasteSplitAcrossReads() {
        var decoder = KeyDecoder()
        #expect(decoder.decode(Array("\u{1B}[200~abc\u{1B}[20".utf8)) == [])
        #expect(decoder.decode(Array("1~".utf8)) == [.paste("abc")])
        #expect(decoder.decode(Array("\u{1B}[200~a".utf8)) == [])
        #expect(decoder.decode(Array("\nb\u{1B}[201~".utf8)) == [.paste("a\nb")])
    }

    @Test func c1ControlsAreNotText() {
        #expect(keys("a\u{9B}b") == [.text("ab")])
    }
}

@Suite struct LineEditorTests {
    private func type(_ keys: [Key], into editor: inout LineEditor) {
        for key in keys { _ = editor.apply(key) }
    }

    @Test func insertAndDeleteAtTheCursor() {
        var editor = LineEditor()
        type([.text("helo"), .left, .text("l"), .end, .text("!"), .home, .delete], into: &editor)
        #expect(editor.text == "ello!")
        #expect(editor.cursor == 0)
        type([.end, .backspace, .backspace], into: &editor)
        #expect(editor.text == "ell")
    }

    @Test func enterSubmitsAndRecordsHistory() {
        var editor = LineEditor()
        type([.text("first")], into: &editor)
        #expect(editor.apply(.enter) == .submit("first"))
        #expect(editor.text.isEmpty)
        #expect(editor.apply(.enter) == .submit(""))
        #expect(editor.history == ["first"])
    }

    @Test func wordAndLineDeletion() {
        var editor = LineEditor()
        type([.text("git commit  -m"), .control("w")], into: &editor)
        #expect(editor.text == "git commit  ")
        type([.control("w")], into: &editor)
        #expect(editor.text == "git ")
        type([.text("push origin"), .wordLeft, .control("k")], into: &editor)
        #expect(editor.text == "git push ")
        type([.control("u")], into: &editor)
        #expect(editor.text.isEmpty)
    }

    @Test func combiningMarksStayWithTheirLetter() {
        var editor = LineEditor()
        type([.text("e"), .text("\u{301}"), .text("x")], into: &editor)
        #expect(editor.text == "éx")
        #expect(editor.cursor == 2)
        type([.left, .backspace], into: &editor)
        #expect(editor.text == "x")
    }

    @Test func multiLineUpAndDownMoveBetweenLines() {
        var editor = LineEditor(history: ["old"])
        type([.text("abc"), .newline, .text("de"), .newline, .text("fghij")], into: &editor)
        #expect(editor.cursorLocation == (2, 5))
        type([.up], into: &editor)
        #expect(editor.cursorLocation == (1, 2))  // clamped to the shorter line
        type([.up], into: &editor)
        #expect(editor.cursorLocation == (0, 2))
        type([.down, .down], into: &editor)
        #expect(editor.cursorLocation == (2, 2))
        type([.home], into: &editor)
        #expect(editor.cursorLocation == (2, 0))
        #expect(editor.text == "abc\nde\nfghij")
    }

    @Test func historyNavigationKeepsTheDraft() {
        var editor = LineEditor(history: ["one", "two"])
        type([.text("draft"), .up], into: &editor)
        #expect(editor.text == "two")
        type([.up, .up], into: &editor)
        #expect(editor.text == "one")
        type([.down], into: &editor)
        #expect(editor.text == "two")
        type([.down], into: &editor)
        #expect(editor.text == "draft")
        #expect(editor.cursor == 5)
    }

    @Test func appKeysAreLeftToTheApp() {
        var editor = LineEditor()
        #expect(editor.apply(.escape) == .unhandled)
        #expect(editor.apply(.control("c")) == .unhandled)
        #expect(editor.apply(.control("d")) == .unhandled)  // empty prompt: quit
        type([.text("ab"), .home], into: &editor)
        #expect(editor.apply(.control("d")) == .edited)  // otherwise: delete forward
        #expect(editor.text == "b")
    }

    @Test func historySkipsRepeatsAndIsCapped() {
        var editor = LineEditor(historyLimit: 2)
        for entry in ["a", "a", "  ", "b", "c"] { editor.record(entry) }
        #expect(editor.history == ["b", "c"])
    }
}

@Suite struct LayoutTests {
    @Test func displayWidth() {
        #expect(TextWidth.of("abc") == 3)
        #expect(TextWidth.of("نواة") == 4)
        #expect(TextWidth.of("مَرْحَبًا") == 5)  // harakat take no column
        #expect(TextWidth.of("日本語") == 6)
        #expect(TextWidth.of("😀👍🏽🇸🇦") == 6)
        #expect(TextWidth.of("❤️") == 2)
        #expect(TextWidth.of("e\u{301}") == 1)
        #expect(TextWidth.of("한글") == 4)
    }

    @Test func wrapsAtSpacesWithinWidth() {
        let rows = TextWidth.wrap("the quick brown fox jumps over the lazy dog", width: 20)
        #expect(rows == ["the quick brown fox", "jumps over the lazy", "dog"])
        #expect(rows.allSatisfy { TextWidth.of($0) <= 20 })
    }

    @Test func keepsNewlinesAndIndentation() {
        #expect(TextWidth.wrap("a\n\n    b", width: 80) == ["a", "", "    b"])
    }

    @Test func splitsLongWordsAndNeverHalvesAWideCharacter() {
        #expect(TextWidth.wrap("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
        let rows = TextWidth.wrap("日本語のテキスト", width: 5)
        #expect(rows == ["日本", "語の", "テキ", "スト"])
        #expect(TextWidth.wrap("😀😀😀", width: 5) == ["😀😀", "😀"])
    }

    @Test func wrapsArabic() {
        let rows = TextWidth.wrap("نواة هي نواة الوكيل البسيط", width: 10)
        #expect(rows == ["نواة هي", "نواة", "الوكيل", "البسيط"])
    }

    @Test func paragraphNeverUsesTheLastColumn() {
        let layout = Layout(columns: 20)
        let lines = layout.paragraph(String(repeating: "word ", count: 20), prefix: StyledSpan("● "))
        #expect(lines.allSatisfy { $0.width <= 19 })
        #expect(lines[0].text.hasPrefix("● word"))
        #expect(lines[1].text.hasPrefix("  word"))
    }

    @Test func paragraphAt80Columns() {
        let text = "Fixed: FileWalk now merges nested .gitignore files (FileWalk.swift:88). The suite passes."
        let lines = Layout(columns: 80).paragraph(text, prefix: StyledSpan("● "))
        #expect(lines.map(\.text) == [
            "● Fixed: FileWalk now merges nested .gitignore files (FileWalk.swift:88). The",
            "  suite passes.",
        ])
    }

    @Test func sanitizeStripsControlCharacters() {
        let hostile = "red\u{1B}[31mtext\u{1B}]52;c;aGk=\u{07}\u{9B}2J\u{7F}end"
        #expect(Layout.sanitize(hostile) == "red[31mtext]52;c;aGk=2Jend")
        #expect(Layout.sanitize("a\r\nb\rc\td") == "a\nb\nc   d")
        #expect(Layout.sanitize("ab\tc") == "ab  c")
    }

    @Test func rowCutsToWidth() {
        let line = Layout(columns: 12).row("one\ntwo three four", prefix: StyledSpan("⏺ "))
        #expect(line.text == "⏺ one two …")
        #expect(line.width <= 11)
    }

    @Test func truncate() {
        #expect(TextWidth.truncate("short", width: 10) == "short")
        #expect(TextWidth.truncate("日本語", width: 4) == "日…")
    }
}

@Suite struct ToolDisplayTests {
    @Test func labelsForBuiltInTools() {
        func label(_ name: String, _ arguments: [String: String]) -> ToolLabel {
            ToolLabel(ToolCall(id: "1", name: name, arguments: .object(arguments.mapValues { .string($0) })))
        }
        #expect(label("shell", ["command": "swift test"]) == ToolLabel(name: "shell", detail: "swift test"))
        #expect(label("shell", ["command": "cd x\nmake"]).detail == "cd x …")
        #expect(label("read_file", ["path": "a.swift"]).detail == "a.swift")
        #expect(label("search", ["pattern": "gitignore"]).detail == "gitignore")
        #expect(label("list_files", ["path": "Sources", "glob": "*.swift"]).detail == "Sources *.swift")
        #expect(label("task", ["prompt": "find it\nthen fix"]).detail == "find it …")
        #expect(label("call_tool", ["name": "github__search_issues"]).detail == "github · search_issues")
        #expect(label("github__create_issue", ["title": "Bug"]) == ToolLabel(name: "github · create_issue", detail: #"{"title":"Bug"}"#))
        #expect(label("current_time", [:]) == ToolLabel(name: "current_time", detail: ""))
    }

    @Test func shellSummaryWithExitCode() {
        let result = ToolCallResult(callID: "1", name: "shell", content: "exit code: 1\nerror: a\nerror: b\n", isError: true)
        #expect(ResultSummary(result) == ResultSummary(text: "exit 1 · 2 lines", isError: true))
    }

    @Test func summaryCountsOmittedLinesAndShowsTheLog() {
        let lines = (["head"] + ["[… 41 lines omitted; full output at /tmp/nawa-7F1B3985.log]"] + ["tail"]).joined(separator: "\n")
        let summary = ResultSummary(ToolCallResult(callID: "1", name: "shell", content: "exit code: 1\n" + lines, isError: true))
        #expect(summary.text == "exit 1 · 43 lines · full output: /tmp/nawa-7F1B3985.log")
        #expect(summary.fullOutputPath == "/tmp/nawa-7F1B3985.log")
    }

    @Test func shortenedLinesMarker() {
        let summary = ResultSummary(ToolCallResult(callID: "1", name: "read_file", content: "a […]\n[long lines shortened; full output at /tmp/x.log]"))
        #expect(summary == ResultSummary(text: "1 line · full output: /tmp/x.log", fullOutputPath: "/tmp/x.log"))
    }

    @Test func errorsShowTheirFirstLine() {
        let summary = ResultSummary(ToolCallResult(callID: "1", name: "read_file", content: "\nno such file: a.swift\nmore", isError: true))
        #expect(summary == ResultSummary(text: "no such file: a.swift", isError: true))
    }

    @Test func noOutput() {
        let summary = ResultSummary(ToolCallResult(callID: "1", name: "shell", content: "exit code: 0\n(no output)"))
        #expect(summary.text == "exit 0 · no output")
    }
}

// MARK: - Transcript

func call(_ id: String, _ name: String, _ arguments: [String: String] = [:]) -> ToolCall {
    ToolCall(id: id, name: name, arguments: .object(arguments.mapValues { .string($0) }))
}

func turn(_ text: String = "", _ calls: [ToolCall] = [], session: Int = 0, cost: Double? = nil) -> AgentEvent {
    .assistant(AssistantUpdate(text: text, toolCalls: calls, usage: Usage(inputTokens: session), sessionUsage: Usage(inputTokens: session), sessionCost: cost))
}

func result(_ kind: AgentResultKind = .success, turns: Int = 1, tokens: Int = 0, cost: Double? = nil, error: String? = nil) -> AgentResult {
    AgentResult(kind: kind, usage: Usage(inputTokens: tokens), numTurns: turns, sessionID: "s", costEstimate: cost, errorMessage: error)
}

@Suite struct TranscriptTests {
    @Test func parallelToolCallsRunLiveThenCommitInOrder() {
        var transcript = Transcript()
        #expect(transcript.submit("fix it") == [.prompt("fix it")])
        #expect(transcript.live.phase == .waiting)

        let blocks = transcript.reduce(turn("Running both.\n", [call("a", "shell", ["command": "swift test"]), call("b", "read_file", ["path": "x.swift"])], session: 120, cost: 0.01))
        #expect(blocks == [.assistant("Running both.")])
        #expect(transcript.live.phase == .runningTools)
        #expect(transcript.live.running.map(\.id) == ["a", "b"])
        #expect(transcript.stats.usage.total == 120)
        #expect(transcript.stats.cost == 0.01)

        let committed = transcript.reduce(.toolResults([
            ToolCallResult(callID: "a", name: "shell", content: "exit code: 0\nok"),
            ToolCallResult(callID: "b", name: "read_file", content: "one\ntwo"),
        ]))
        #expect(committed == [
            .tool(ToolBlock(label: ToolLabel(name: "shell", detail: "swift test"), summary: ResultSummary(text: "exit 0 · 1 line"))),
            .tool(ToolBlock(label: ToolLabel(name: "read_file", detail: "x.swift"), summary: ResultSummary(text: "2 lines"))),
        ])
        #expect(transcript.live.running.isEmpty)
        #expect(transcript.live.phase == .waiting)
        #expect(transcript.live.turn == 2)

        #expect(transcript.reduce(turn("Done.", session: 300)) == [.assistant("Done.")])
        #expect(transcript.reduce(.result(result())) == [])
        #expect(transcript.live.phase == .idle)
    }

    @Test func subAgentStepsAttachToTheirTaskCall() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(turn("", [call("t", "task", ["prompt": "find the parser"])]))

        func sub(_ event: AgentEvent, callID: String = "t") -> AgentEvent {
            .subAgent(SubAgentUpdate(callID: callID, model: "haiku", event: event))
        }
        #expect(transcript.reduce(sub(turn("", [call("s1", "search", ["pattern": "gitignore"])]))) == [])
        #expect(transcript.reduce(sub(turn("Found it."))) == [])
        #expect(transcript.reduce(sub(.result(result(turns: 3, tokens: 8200, cost: 0.004)))) == [])
        // An update for a call that isn't running is ignored.
        #expect(transcript.reduce(sub(turn("stray"), callID: "nope")) == [])

        let trace = transcript.live.running.first?.subAgent
        #expect(trace?.model == "haiku")
        #expect(trace?.steps == [.tool(ToolLabel(name: "search", detail: "gitignore")), .text("Found it.")])
        #expect(trace?.outcome == "done · 3 turns · 8.2k tokens · $0.0040")

        let blocks = transcript.reduce(.toolResults([ToolCallResult(callID: "t", name: "task", content: "Found it.")]))
        guard case .tool(let block)? = blocks.first else { Issue.record("no tool block"); return }
        #expect(block.subAgent == trace)
    }

    @Test func failedRunWarnsAndClearsRunningCalls() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(turn("", [call("a", "shell", ["command": "make"])]))
        let blocks = transcript.reduce(.result(result(.errorDuringExecution, error: "HTTP 529 overloaded")))
        #expect(blocks == [
            .tool(ToolBlock(label: ToolLabel(name: "shell", detail: "make"), summary: nil)),
            .warning("error_during_execution: HTTP 529 overloaded"),
        ])
        #expect(!transcript.live.isBusy)
    }

    @Test func limitsSayWhatHappened() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        #expect(transcript.reduce(.result(result(.errorMaxBudgetUSD, cost: 1.25))) == [.warning("stopped: the budget is spent ($1.25)")])
        _ = transcript.submit("go")
        #expect(transcript.reduce(.result(result(.errorMaxTurns, turns: 20))) == [.note("stopped after 20 turns; send \"continue\" to keep going")])
    }

    @Test func interruptionMarksUnfinishedCalls() {
        var transcript = Transcript()
        #expect(transcript.interrupt() == [])  // nothing running
        _ = transcript.submit("go")
        _ = transcript.reduce(turn("", [call("a", "shell", ["command": "sleep 60"])]))
        #expect(transcript.interrupt() == [
            .tool(ToolBlock(label: ToolLabel(name: "shell", detail: "sleep 60"), summary: nil)),
            .warning("interrupted"),
        ])
        #expect(transcript.interrupt() == [])  // only once
    }

    @Test func notesAndIgnoredEvents() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        #expect(transcript.reduce(.informational("Compacted 40 older messages into a summary.")) == [.note("Compacted 40 older messages into a summary.")])
        #expect(transcript.reduce(.toolResult(ToolCallResult(callID: "a", name: "shell", content: ""))) == [])
    }

    @Test func streamedRepliesAreLiveUntilTheTurnCommitsThem() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        let start = ContinuousClock.now

        #expect(transcript.reduce(.stream(.thinkingDelta("Let me look")), now: start) == [])
        #expect(transcript.live.phase == .thinking)
        #expect(transcript.reduce(.stream(.textDelta("Hel")), now: start + .seconds(4)) == [])
        #expect(transcript.reduce(.stream(.textDelta("lo")), now: start + .seconds(5)) == [])
        #expect(transcript.live.phase == .writing)
        #expect(transcript.live.inFlight.thinking == "Let me look")
        #expect(transcript.live.inFlight.text == "Hello")
        #expect(transcript.live.inFlight.characters == 16)

        // Reasoning ended when the text began: 4s, not 6s.
        #expect(transcript.reduce(turn("Hello"), now: start + .seconds(6)) == [.note("thought for 4s"), .assistant("Hello")])
        #expect(transcript.live.inFlight == LiveState.InFlight())
    }

    @Test func aTurnWithoutReasoningHasNoThoughtNote() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(.stream(.textDelta("Hi")))
        #expect(transcript.reduce(turn("Hi")) == [.assistant("Hi")])
    }

    @Test func aToolCallBeingWrittenIsShownByName() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(.stream(.toolCallStart(ToolCall(id: "a", name: "shell"))))
        _ = transcript.reduce(.stream(.toolCallArgumentsDelta(id: "a", partialJSON: #"{"command":"#)))
        #expect(transcript.live.phase == .preparingTool)
        #expect(transcript.live.inFlight.preparing?.name == "shell")
        #expect(transcript.live.inFlight.characters == 11)
    }

    @Test func onlyTheNewestStreamedTextIsKept() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        for _ in 0..<100 { _ = transcript.reduce(.stream(.textDelta(String(repeating: "x", count: 100)))) }
        _ = transcript.reduce(.stream(.textDelta("end")))
        #expect(transcript.live.inFlight.text.count <= LiveState.InFlight.keep * 2)
        #expect(transcript.live.inFlight.text.hasSuffix("end"))
        #expect(transcript.live.inFlight.characters == 10_003)
    }

    @Test func anInterruptDropsTheStreamedText() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(.stream(.textDelta("Hal")))
        #expect(transcript.interrupt() == [.warning("interrupted")])
        #expect(transcript.live.inFlight.text.isEmpty)
    }

    @Test func shortNumbers() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(8200) == "8.2k")
        #expect(Format.tokens(48_100) == "48.1k")
        #expect(Format.tokens(120_000) == "120k")
        #expect(Format.tokens(999_999) == "1M")
        #expect(Format.tokens(1_234_567) == "1.2M")
        #expect(Format.cost(0.004) == "$0.0040")
        #expect(Format.cost(0.031) == "$0.031")
        #expect(Format.cost(1.254) == "$1.25")
    }
}

// MARK: - Transcript layout

@Suite struct TranscriptLayoutTests {
    let layout = Layout(columns: 60)

    private func texts(_ lines: [StyledLine]) -> [String] { lines.map(\.text) }

    @Test func blocks() {
        #expect(texts(layout.lines(for: .prompt("fix it"))) == ["", "› fix it"])
        #expect(texts(layout.lines(for: .assistant("one\ntwo"))) == ["● one", "  two"])
        #expect(texts(layout.lines(for: .note("Compacted."))) == ["· Compacted."])
        #expect(texts(layout.lines(for: .warning("interrupted"))) == ["⚠ interrupted"])
    }

    @Test func toolBlockWithSummaryAndLogPath() {
        let summary = ResultSummary(text: "exit 1 · 43 lines · full output: /tmp/nawa-1.log", isError: true, fullOutputPath: "/tmp/nawa-1.log")
        let lines = layout.lines(for: .tool(ToolBlock(label: ToolLabel(name: "shell", detail: "swift test"), summary: summary)))
        #expect(texts(lines) == ["  ⏺ shell  swift test", "    └ exit 1 · 43 lines · full output: /tmp/nawa-1.log"])
        #expect(lines[1].spans.last?.style == .color(.red))
    }

    @Test func unfinishedToolBlock() {
        let lines = layout.lines(for: .tool(ToolBlock(label: ToolLabel(name: "shell", detail: "make"), summary: nil)))
        #expect(texts(lines) == ["  ⏺ shell  make", "    └ interrupted"])
    }

    @Test func taskBlockShowsTheSubAgentAndItsOutcome() {
        var trace = SubAgentTrace(model: "haiku")
        trace.steps = [.tool(ToolLabel(name: "search", detail: "gitignore")), .text("Found it.")]
        trace.outcome = "done · 3 turns · 8.2k tokens"
        let block = ToolBlock(label: ToolLabel(name: "task", detail: "find the parser"), summary: ResultSummary(text: "1 line"), subAgent: trace)
        #expect(texts(layout.lines(for: .tool(block))) == [
            "  ⏺ task  find the parser",
            "    ↳ haiku",
            "      ⏺ search  gitignore",
            "      ● Found it.",
            "    └ done · 3 turns · 8.2k tokens",
        ])
    }

    @Test func longSubAgentTracesCountTheHiddenSteps() {
        var trace = SubAgentTrace(model: nil)
        trace.steps = (1...10).map { .text("step \($0)") }
        let lines = texts(layout.subAgentLines(trace, indent: 4, finished: true))
        #expect(lines.prefix(3) == ["    ↳ sub-agent", "      ⋯ 2 earlier steps", "      ● step 3"])
        #expect(lines.count == 2 + Layout.maxSubAgentSteps)
        // While running, only the latest step.
        #expect(texts(layout.subAgentLines(trace, indent: 4, finished: false)) == ["    ↳ sub-agent", "      ● step 10"])
    }

    @Test func callRowsFitOneRowAndStripEscapes() {
        let narrow = Layout(columns: 20)
        let row = narrow.callRow(ToolLabel(name: "shell", detail: "echo \u{1B}]52;c;aGk=\u{07} and a long tail"), indent: 2)
        #expect(row.width <= narrow.width)
        #expect(!row.text.contains("\u{1B}"))
        #expect(row.text.hasPrefix("  ⏺ shell  echo"))
        #expect(row.text.hasSuffix("…"))
    }

    @Test func headerAndFooter() {
        let facts = SessionHeader(provider: "anthropic", model: "claude-sonnet-4-5", directory: "~/src/nawa", instructionsFile: "AGENTS.md")
        #expect(Layout(columns: 80).header(facts).text == " nawa · anthropic · claude-sonnet-4-5 · ~/src/nawa · AGENTS.md")
        #expect(layout.header(facts).text.hasSuffix("AGENT…"))  // cut to one row
        #expect(layout.header(SessionHeader(directory: "/tmp")).text == " nawa · /tmp")
        let withSkills = SessionHeader(directory: "/tmp", instructionsFile: "CLAUDE.md", skillCount: 3)
        #expect(Layout(columns: 80).header(withSkills).text == " nawa · /tmp · CLAUDE.md · 3 skills")

        var stats = SessionStats()
        stats.usage = Usage(inputTokens: 17_100, outputTokens: 0, cacheReadTokens: 31_000)
        stats.cost = 0.031
        stats.contextTokens = 27_600
        #expect(Layout(columns: 100).footer(stats, contextLimit: 120_000, extra: "/help").text == " 48.1k tokens used (31k cached) · $0.031 · context 27.6k/120k (23%) · /help")
        #expect(layout.footer(SessionStats(), contextLimit: nil).text == " 0 tokens used")
    }
}

// MARK: - Plain mode

@Suite struct PlainChatTests {
    private func scripted(_ events: [AgentEvent], fail: (any Error)? = nil) -> ChatSession {
        ChatSession(header: SessionHeader(directory: "~/p"), contextLimit: 1000) { _ in
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: fail)
            }
        }
    }

    private func run(_ session: ChatSession, input: [String], echoPrompts: Bool = true) async -> String {
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        var lines = input[...]
        let chat = PlainChat(session: session, layout: Layout(columns: 80), echoPrompts: echoPrompts) { sink.text += $0 }
        await chat.run { lines.popFirst() }
        return sink.text
    }

    @Test func runPrintsCommittedBlocksThenTheFooter() async {
        let session = scripted([
            turn("Checking.", [call("a", "shell", ["command": "ls"])], session: 100),
            .toolResults([ToolCallResult(callID: "a", name: "shell", content: "exit code: 0\na\nb")]),
            turn("Two files.", session: 250, cost: 0.002),
            .result(result()),
        ])
        let output = await run(session, input: ["  ", "list files"])
        #expect(output == """
             nawa · ~/p

            › list files
            ● Checking.
              ⏺ shell  ls
                └ exit 0 · 2 lines
            ● Two files.
             250 tokens used · $0.0020 · context 250/1k (25%)

            """)
    }

    @Test func aTerminalEchoesThePromptSoItIsNotRepeated() async {
        let output = await run(scripted([turn("Hi.", session: 10), .result(result())]), input: ["hello"], echoPrompts: false)
        #expect(output == """
             nawa · ~/p
            Type a prompt and press Enter; /help lists commands, Ctrl-D quits.
            ● Hi.
             10 tokens used · context 10/1k (1%)


            """)
    }

    @Test func aStreamThatEndsEarlyIsInterruptedAndErrorsAreShown() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "connection reset" } }
        let cut = await run(scripted([turn("", [call("a", "shell", ["command": "make"])])]), input: ["go"])
        #expect(cut.contains("  ⏺ shell  make\n    └ interrupted\n⚠ interrupted\n"))
        let failed = await run(scripted([], fail: Boom()), input: ["go"])
        #expect(failed.hasSuffix("› go\n⚠ connection reset\n"))
    }

    @Test func shiftEnterFromModifyOtherKeysBecomesNewline() {
        let line = "last session returned this error:\u{1B}[27;2;13~1. Inline."
        #expect(PlainChat.modifiedEnterAsNewline(line) == "last session returned this error:\n1. Inline.")
    }

    @Test func shiftEnterFromKittyProtocolBecomesNewline() {
        #expect(PlainChat.modifiedEnterAsNewline("a\u{1B}[13;2ub\u{1B}[13;5uc") == "a\nb\nc")
    }

    @Test func sequenceWithoutEscIsStillANewline() {
        #expect(PlainChat.modifiedEnterAsNewline("error:[27;2;13~1.") == "error:\n1.")
    }

    @Test func ordinaryTextIsUntouched() {
        let line = "array[27] and [13;2] stay as they are"
        #expect(PlainChat.modifiedEnterAsNewline(line) == line)
    }
}

@Suite struct SlashCommandTests {
    @Test func parsesCommandsAndLeavesPromptsAlone() {
        #expect(SlashCommand("/help") == .help)
        #expect(SlashCommand("  /CLEAR  ") == .clear)
        #expect(SlashCommand("/cost please") == .cost)
        #expect(SlashCommand("/frobnicate") == .unknown("/frobnicate"))
        #expect(SlashCommand("fix /help") == nil)
        #expect(SlashCommand("/usr/bin/env is missing") == nil)
        #expect(SlashCommand("/") == nil)
    }

    @Test func clearResetsTheSessionUnlessARunIsBusy() {
        final class Resets: @unchecked Sendable { var count = 0 }
        let resets = Resets()
        let session = ChatSession(header: SessionHeader(directory: "~"), send: { _ in AsyncThrowingStream { $0.finish() } }, reset: { resets.count += 1 })

        let busy = SlashCommand.clear.perform(stats: SessionStats(), session: session, busy: true)
        #expect(busy.effect == .none)
        #expect(resets.count == 0)

        let idle = SlashCommand.clear.perform(stats: SessionStats(), session: session, busy: false)
        #expect(idle.effect == .cleared)
        #expect(resets.count == 1)
    }

    @Test func costBreaksTheTokensDown() {
        var stats = SessionStats()
        stats.usage = Usage(inputTokens: 2100, outputTokens: 500, cacheReadTokens: 9800)
        stats.cost = 0.012
        stats.contextTokens = 90
        #expect(SlashCommand.costReport(stats, contextLimit: 1000) == "12.4k tokens: 2.1k input, 9.8k cached, 500 output · $0.012 · context 90/1k (9%)")
        #expect(SlashCommand.costReport(SessionStats(), contextLimit: nil) == "nothing spent yet")
    }

    @Test func toolsListsTheSessionsTools() {
        let session = ChatSession(header: SessionHeader(directory: "~"), tools: ["shell", "read_file"], send: { _ in AsyncThrowingStream { $0.finish() } })
        #expect(SlashCommand.tools.perform(stats: SessionStats(), session: session, busy: false).blocks == [.note("2 tools: shell, read_file")])
    }

    @Test func plainModeRunsCommandsInsteadOfSendingThem() async {
        final class Sent: @unchecked Sendable { var prompts: [String] = [] }
        let sent = Sent()
        let session = ChatSession(header: SessionHeader(directory: "~/p"), send: { prompt in
            sent.prompts.append(prompt)
            return AsyncThrowingStream { $0.finish() }
        })
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        var lines = ["/tools", "/nope", "/exit", "never sent"][...]
        await PlainChat(session: session, layout: Layout(columns: 80), echoPrompts: true) { sink.text += $0 }.run { lines.popFirst() }

        #expect(sent.prompts.isEmpty)
        #expect(sink.text == """
             nawa · ~/p
            · no tools
            ⚠ unknown command /nope; /help lists them

            """)
    }
}

@Suite struct ResumedHistoryTests {
    static func conversation(prompts: Int) -> [Message] {
        var messages = [Message(role: .system, text: "Be brief.")]
        for number in 1...prompts {
            messages.append(Message(role: .user, text: "prompt \(number)"))
            messages.append(Message(role: .assistant, text: "answer \(number)"))
        }
        return messages
    }

    @Test func theLastPromptsAreShownAndEarlierOnesCounted() {
        let blocks = Transcript.blocks(replaying: Self.conversation(prompts: 5))
        #expect(blocks == [
            .note("2 earlier prompts"),
            .prompt("prompt 3"), .assistant("answer 3"),
            .prompt("prompt 4"), .assistant("answer 4"),
            .prompt("prompt 5"), .assistant("answer 5"),
            .note("resumed: the conversation goes on from here"),
        ])
    }

    @Test func toolCallsShowWithTheirResults() {
        let call = ToolCall(id: "c1", name: "read_file", arguments: .object(["path": .string("a.swift")]))
        let messages = [
            Message(role: .user, text: "read it"),
            Message(role: .assistant, content: [.toolCall(call)]),
            ToolCallResult(callID: "c1", name: "read_file", content: "let a = 1").asMessage,
            Message(role: .assistant, text: "Read."),
        ]
        let blocks = Transcript.blocks(replaying: messages)
        let tool = ToolBlock(label: ToolLabel(call), summary: ResultSummary(ToolCallResult(callID: "c1", name: "read_file", content: "let a = 1")))
        #expect(blocks == [.prompt("read it"), .tool(tool), .assistant("Read."), .note("resumed: the conversation goes on from here")])
    }

    @Test func aNewSessionShowsNothing() {
        #expect(Transcript.blocks(replaying: []).isEmpty)
        #expect(Transcript.blocks(replaying: [Message(role: .system, text: "Be brief.")]).isEmpty)
    }

    @Test func plainChatShowsTheHistoryUnderTheHeader() async {
        var output = ""
        let session = ChatSession(
            header: SessionHeader(provider: nil, model: nil, directory: "~"),
            history: Self.conversation(prompts: 1),
            send: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let chat = PlainChat(session: session, layout: Layout(columns: 80), echoPrompts: true) { output += $0 }
        await chat.run { nil }
        #expect(output.contains("prompt 1"))
        #expect(output.contains("answer 1"))
        #expect(output.contains("resumed"))
    }
}

@Suite struct ConfigCommandTests {
    @Test func configKeepsItsWords() {
        #expect(SlashCommand("/config") == .config([]))
        #expect(SlashCommand("/config set compact_at 200k") == .config(["set", "compact_at", "200k"]))
        #expect(SlashCommand("/CONFIG  unset   stream") == .config(["unset", "stream"]))
        #expect(SlashCommand("/cost extra words") == .cost)
    }

    @Test func configRunsTheSessionsHookAndShowsItsLines() {
        let received = Mutex<[String]>([])
        let session = ChatSession(
            header: SessionHeader(directory: "~"),
            send: { _ in AsyncThrowingStream { $0.finish() } },
            configure: { arguments in
                received.withLock { $0 = arguments }
                return ["compact_at = 200k; takes effect now"]
            }
        )

        let (blocks, effect) = SlashCommand.config(["set", "compact_at", "200k"]).perform(stats: SessionStats(), session: session, busy: true)

        #expect(received.withLock { $0 } == ["set", "compact_at", "200k"])
        #expect(blocks == [.note("compact_at = 200k; takes effect now")])
        #expect(effect == .none)
    }

    @Test func withoutAHookConfigSaysSo() {
        let session = ChatSession(header: SessionHeader(directory: "~"), send: { _ in AsyncThrowingStream { $0.finish() } })

        let (blocks, _) = SlashCommand.config([]).perform(stats: SessionStats(), session: session, busy: false)

        #expect(blocks == [.warning("this session has no settings to change")])
    }

    @Test func theFooterFollowsALiveContextLimit() {
        let limit = Mutex(120_000)
        let session = ChatSession(
            header: SessionHeader(directory: "~"),
            contextLimit: 1,
            send: { _ in AsyncThrowingStream { $0.finish() } },
            liveContextLimit: { limit.withLock { $0 } }
        )
        #expect(session.contextLimit == 120_000)
        limit.withLock { $0 = 600_000 }
        #expect(session.contextLimit == 600_000)
    }
}
