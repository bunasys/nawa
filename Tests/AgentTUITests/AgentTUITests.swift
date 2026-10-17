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
