import Testing
import AgentCore
@testable import AgentTUI

/// Just enough of a VT100 to replay what `InlineScreen` writes: printable
/// text, CR, LF, cursor up/right, erase below / to end of line, SGR and
/// the private modes. Anything else is recorded in `unknown`.
struct VirtualTerminal {
    let columns: Int
    private(set) var lines: [[String]] = [[]]
    private(set) var row = 0
    private(set) var column = 0
    private(set) var cursorVisible = true
    private(set) var unknown: [String] = []
    /// Set when a character landed in the last column.
    private(set) var wroteLastColumn = false

    init(columns: Int) { self.columns = columns }

    var screen: String {
        lines.map { cells in
            var text = cells.joined()
            while text.last == " " { text.removeLast() }
            return text
        }.joined(separator: "\n")
    }

    mutating func feed(_ text: String) {
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            switch character {
            case "\u{1B}":
                guard characters.popFirst() == "[" else { unknown.append("ESC"); continue }
                var sequence = ""
                while let next = characters.popFirst() {
                    sequence.append(next)
                    if let ascii = next.asciiValue, (0x40...0x7E).contains(ascii) { break }
                }
                apply(sequence)
            case "\r\n":
                column = 0
                lineFeed()
            case "\r": column = 0
            case "\n": lineFeed()
            default: put(character)
            }
        }
    }

    private mutating func lineFeed() {
        row += 1
        if row == lines.count { lines.append([]) }
    }

    private mutating func put(_ character: Character) {
        let width = TextWidth.of(character)
        while lines[row].count < column + width { lines[row].append(" ") }
        lines[row][column] = String(character)
        if width == 2 { lines[row][column + 1] = "" }
        column += width
        if column >= columns { wroteLastColumn = true }
    }

    private mutating func apply(_ sequence: String) {
        let count = Int(sequence.dropLast()) ?? 1
        switch sequence {
        case "?25l": cursorVisible = false
        case "?25h": cursorVisible = true
        case "?2004h", "?2004l": break
        case "J":
            lines[row] = Array(lines[row].prefix(column))
            lines.removeLast(lines.count - row - 1)
        case "K": lines[row] = Array(lines[row].prefix(column))
        case _ where sequence.hasSuffix("m"): break
        case _ where sequence.hasSuffix("A"): row = max(row - count, 0)
        case _ where sequence.hasSuffix("C"): column += count
        default: unknown.append(sequence)
        }
    }
}

@Suite struct InlineScreenTests {
    @Test func aFrameIsRelativeMovesAndText() {
        var screen = InlineScreen(color: false)
        let first = screen.frame(columns: 80, committed: [], live: ["a", "b"], cursor: .init(row: 0, column: 1))
        #expect(first == "\u{1B}[?25l\r\u{1B}[Ja\r\nb\u{1B}[1A\r\u{1B}[1C\u{1B}[?25h")
        // Next frame: back up from the cursor's row (0) to the top, then redraw.
        let second = screen.frame(columns: 80, committed: ["x"], live: ["y"], cursor: nil)
        #expect(second == "\u{1B}[?25l\r\u{1B}[Jx\r\ny")
        #expect(!(first + second).contains("\u{1B}[?1049"))
    }

    @Test func committedLinesStayAboveAndTheLiveRegionIsReplaced() {
        var screen = InlineScreen(color: true)
        var terminal = VirtualTerminal(columns: 40)
        terminal.feed(screen.frame(columns: 40, committed: ["one"], live: ["status", "box", "footer"], cursor: .init(row: 1, column: 3)))
        terminal.feed(screen.frame(columns: 40, committed: ["two", "three"], live: ["box"], cursor: .init(row: 0, column: 0)))
        #expect(terminal.screen == "one\ntwo\nthree\nbox")
        terminal.feed(screen.clear(columns: 40, committed: ["four"]))
        #expect(terminal.screen == "one\ntwo\nthree\nfour\n")
        #expect(terminal.cursorVisible)
        #expect(terminal.unknown.isEmpty)
    }

    @Test func stylesBecomeSGRAndNoColorKeepsOnlyBoldAndDim() {
        let line = StyledLine([StyledSpan("a", Style(bold: true, color: .red)), StyledSpan("b", .color(.brightCyan)), StyledSpan("c")])
        #expect(Escape.render(line, color: true) == "\u{1B}[1;31ma\u{1B}[0m\u{1B}[96mb\u{1B}[0mc")
        #expect(Escape.render(line, color: false) == "\u{1B}[1ma\u{1B}[0mbc")
    }

    @Test func aNarrowerWindowCountsTheRowsTheTerminalReflowed() {
        var screen = InlineScreen(color: false)
        let wide = StyledLine(String(repeating: "x", count: 30))
        _ = screen.frame(columns: 40, committed: [], live: [wide, "box"], cursor: .init(row: 1, column: 0))
        // At 20 columns the 30-column row now takes two rows.
        let frame = screen.frame(columns: 20, committed: [], live: ["box"], cursor: nil)
        #expect(frame.hasPrefix("\u{1B}[?25l\u{1B}[2A\r\u{1B}[J"))
    }
}

@Suite struct LiveRegionTests {
    let layout = Layout(columns: 20)  // text width 19, box text 13

    @Test func promptBoxDrawsTheTextAndPlacesTheCursor() {
        let box = layout.promptBox("hello", cursor: 5, maxRows: 5)
        #expect(box.lines.map(\.text) == [
            "╭─────────────────╮",
            "│ › hello         │",
            "╰─────────────────╯",
        ])
        #expect(box.lines.allSatisfy { $0.width == 19 })
        #expect(box.cursor == InlineScreen.Cursor(row: 1, column: 9))
    }

    @Test func promptBoxWrapsAndMovesTheCursorToAFreshRowWhenFull() {
        let full = String(repeating: "a", count: 13)
        let box = layout.promptBox(full, cursor: 13, maxRows: 5)
        #expect(box.lines.count == 4)
        #expect(box.cursor == InlineScreen.Cursor(row: 2, column: 4))

        let wrapped = layout.promptBox(full + "b\nc", cursor: 2, maxRows: 5)
        #expect(wrapped.lines.map(\.text)[1...3] == ["│ › aaaaaaaaaaaaa │", "│   b             │", "│   c             │"])
        #expect(wrapped.cursor == InlineScreen.Cursor(row: 1, column: 6))
    }

    @Test func promptBoxScrollsToTheCursorAndHidesControlCharacters() {
        let box = layout.promptBox("one\ntwo\nthr\u{1B}ee", cursor: 12, maxRows: 1)
        #expect(box.lines.map(\.text)[1] == "│   thr�ee        │")
        #expect(box.cursor == InlineScreen.Cursor(row: 1, column: 8))
    }

    @Test func wideCharactersWrapWhole() {
        let box = layout.promptBox("ab" + String(repeating: "中", count: 6), cursor: 8, maxRows: 5)
        #expect(box.lines.map(\.text)[1...2] == ["│ › ab中中中中中  │", "│   中            │"])
        #expect(box.cursor == InlineScreen.Cursor(row: 2, column: 6))
    }

    @Test func statusShowsActivityAndRunningCalls() {
        var transcript = Transcript()
        _ = transcript.submit("go")
        _ = transcript.reduce(turn("", [call("a", "shell", ["command": "swift test"])]))
        let lines = Layout(columns: 80).status(transcript.live, frame: 2, elapsedSeconds: 65, maxTurns: 20)
        #expect(lines.map(\.text) == [
            " ⠹ running shell · 1m 05s · turn 1/20 · esc to interrupt",
            "  ⠹ shell  swift test",
        ])
        #expect(Layout(columns: 80).status(LiveState(), frame: 0, elapsedSeconds: 0, maxTurns: nil).isEmpty)
    }
}

// MARK: - The inline chat

@MainActor
final class FakeTerminal: TerminalIO {
    let size: TerminalSize
    var output = ""
    var suspended = 0

    init(columns: Int = 60, rows: Int = 24) { size = TerminalSize(columns: columns, rows: rows) }

    func write(_ text: String) { output += text }
    func suspend() { suspended += 1 }

    var screen: VirtualTerminal {
        var terminal = VirtualTerminal(columns: size.columns)
        terminal.feed(output)
        return terminal
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct InlineChatTests {
    /// Each prompt gets the events `reply` returns.
    private func session(_ reply: @escaping @Sendable (String) -> [AgentEvent]) -> ChatSession {
        ChatSession(header: SessionHeader(directory: "~/p"), contextLimit: 1000) { prompt in
            AsyncThrowingStream { continuation in
                for event in reply(prompt) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func run(_ session: ChatSession, keys: [[Key]], endInput: Bool = true) async -> FakeTerminal {
        let terminal = FakeTerminal()
        let chat = InlineChat(session: session, terminal: terminal, color: true)
        let (stream, continuation) = AsyncStream<[Key]>.makeStream()
        for batch in keys { continuation.yield(batch) }
        if endInput { continuation.finish() }
        await chat.run(keys: stream)
        continuation.finish()
        return terminal
    }

    @Test func aPromptAndItsReplyEndUpInScrollback() async {
        let chat = session { prompt in [turn("You said \(prompt).", session: 10), .result(result())] }
        let terminal = await run(chat, keys: [[.text("hi"), .enter]])
        let screen = terminal.screen
        #expect(screen.screen == " nawa · ~/p\n\n› hi\n● You said hi.\n")
        #expect(screen.unknown.isEmpty)
        #expect(!screen.wroteLastColumn)
        #expect(screen.cursorVisible)
        #expect(!terminal.output.contains("\u{1B}[?1049"))
    }

    @Test func promptsSentDuringARunAreQueued() async {
        let chat = session { prompt in [turn("re \(prompt)", session: 10), .result(result())] }
        let terminal = await run(chat, keys: [[.text("one"), .enter, .text("two"), .enter]])
        #expect(terminal.screen.screen.hasSuffix("› one\n● re one\n\n› two\n● re two\n"))
    }

    @Test func escInterruptsTheRunAndCancelsItsStream() async {
        let (ended, endedContinuation) = AsyncStream<Void>.makeStream()
        let chat = ChatSession(header: SessionHeader(directory: "~/p")) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(turn("", [call("a", "shell", ["command": "sleep 100"])]))
                continuation.onTermination = { _ in endedContinuation.yield() }
            }
        }
        let terminal = await run(chat, keys: [[.text("go"), .enter, .escape]])
        var iterator = ended.makeAsyncIterator()
        await iterator.next()
        #expect(terminal.screen.screen.hasSuffix("› go\n⚠ interrupted\n"))
    }

    @Test func ctrlCTwiceOnAnEmptyPromptQuits() async {
        let chat = session { _ in [] }
        let terminal = await run(chat, keys: [[.text("draft"), .control("c"), .control("c"), .control("c")]], endInput: false)
        #expect(terminal.screen.screen == " nawa · ~/p\n")
    }

    @Test func ctrlDOnAnEmptyPromptQuitsAndOtherwiseDeletes() async {
        let chat = session { prompt in [turn(prompt), .result(result())] }
        let edited = await run(chat, keys: [[.text("abc"), .home, .control("d"), .enter]])
        #expect(edited.screen.screen.hasSuffix("› bc\n● bc\n"))
        let quit = await run(chat, keys: [[.control("d")]], endInput: false)
        #expect(quit.screen.screen == " nawa · ~/p\n")
    }

    @Test func theLiveRegionShowsTheBoxAndTheHint() async {
        // Input that stays open: the frame drawn so far is the idle prompt.
        let terminal = FakeTerminal(columns: 30)
        let chat = InlineChat(session: session { _ in [] }, terminal: terminal, color: false)
        let (keys, continuation) = AsyncStream<[Key]>.makeStream()
        continuation.yield([.text("hey")])
        let task = Task { await chat.run(keys: keys) }
        while !terminal.output.contains("hey") { await Task.yield() }
        let screen = terminal.screen
        let rule = String(repeating: "─", count: 27)
        let rows = screen.screen.split(separator: "\n").suffix(4).map(String.init)
        #expect(rows == ["╭\(rule)╮", "│ › hey" + String(repeating: " ", count: 20) + " │", "╰\(rule)╯", " alt-enter for a newline · c…"])
        continuation.finish()
        await task.value
    }
}
