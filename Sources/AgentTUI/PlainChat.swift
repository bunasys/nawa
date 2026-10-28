import AgentCore

/// The chat in line mode: read a prompt, run it, print what it committed.
///
/// Used when there is no terminal to draw on (a pipe, `TERM=dumb`,
/// `--plain`). No colour, no cursor movement, nothing redrawn: the same
/// `Transcript` and `Layout` rows as the inline UI, written as plain text.
public struct PlainChat {
    public var session: ChatSession
    public var layout: Layout
    /// Whether to print the user's prompt as a `› prompt` block. Off when a
    /// terminal already echoed what was typed.
    public var echoPrompts: Bool
    private let write: (String) -> Void

    /// - Parameter write: receives whole lines, each ending in `\n`.
    public init(session: ChatSession, layout: Layout, echoPrompts: Bool, write: @escaping (String) -> Void) {
        self.session = session
        self.layout = layout
        self.echoPrompts = echoPrompts
        self.write = write
    }

    /// Runs until `readLine` returns nil (end of input).
    public func run(readLine: () -> String?) async {
        var transcript = Transcript()
        emit([layout.header(session.header)])
        emit(Transcript.blocks(replaying: session.history))
        if !echoPrompts { emit(["Type a prompt and press Enter; /help lists commands, Ctrl-D quits."]) }

        while let line = readLine() {
            let prompt = Self.modifiedEnterAsNewline(line)
            guard !prompt.allSatisfy(\.isWhitespace) else { continue }
            if let command = SlashCommand(prompt) {
                let (blocks, effect) = command.perform(stats: transcript.stats, session: session, busy: false)
                emit(blocks)
                if effect == .cleared { transcript = Transcript(maxTurns: transcript.maxTurns) }
                if effect == .quit { return }
                continue
            }
            let promptBlocks = transcript.submit(prompt)
            if echoPrompts { emit(promptBlocks) }

            var refusal: RefusalNotice?
            do {
                for try await event in session.send(prompt) {
                    emit(transcript.reduce(event))
                    if case .result(let result) = event { refusal = result.refusal }
                }
                // A stream that ends without a result was cut short.
                emit(transcript.interrupt())
            } catch {
                emit(transcript.fail("\(error)"))
            }
            if transcript.stats.usage.total > 0 {
                emit([layout.footer(transcript.stats, contextLimit: session.contextLimit)])
            }
            // Piped input holds prompts, not answers, so only a person is asked.
            let someoneCanAnswer = !echoPrompts
            if let refusal, someoneCanAnswer {
                emit(layout.paragraph(DeclinedRequest.question(refusal), prefix: StyledSpan("? ")))
                guard let answer = readLine() else { return }
                let remove = DeclinedRequest.wantsRemoval(answer)
                emit(DeclinedRequest.answer(remove: remove, notice: refusal, session: session))
            }
            if !echoPrompts { emit([StyledLine()]) }
        }
    }

    private func emit(_ blocks: [Block]) {
        emit(blocks.flatMap(layout.lines(for:)))
    }

    private func emit(_ lines: [StyledLine]) {
        for line in lines {
            var text = line.text
            while text.last == " " { text.removeLast() }
            write(text + "\n")
        }
    }

    /// Terminals that report modified keys send Shift-Enter (or Ctrl/Alt-Enter)
    /// as `ESC[27;2;13~` (xterm modifyOtherKeys) or `ESC[13;2u` (kitty
    /// protocol). In cooked mode that lands in the line as text, so turn it
    /// back into the newline the user meant. The ESC byte is optional because
    /// some terminals swallow it on echo. The inline UI's `KeyDecoder`
    /// handles the same sequences in raw mode.
    public static func modifiedEnterAsNewline(_ line: String) -> String {
        line.replacing(/\x{1B}?\[(?:27;\d+;13~|13;\d+u)/, with: "\n")
    }
}
