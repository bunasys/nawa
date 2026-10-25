import AgentCore
import Foundation

/// The chat UI for `nawa repl`.
public enum ChatApp {
    public enum Mode: Sendable {
        /// Inline when stdin and stdout are a terminal and `TERM` is set
        /// and not `dumb`; plain otherwise.
        case auto
        /// Line mode: no colour, no cursor movement (`--plain`, pipes).
        case plain
        case inline
    }

    /// Runs until the user quits or input ends. `maxTurns` is the loop's
    /// per-prompt cap, shown in the status line.
    public static func run(
        _ session: ChatSession,
        mode: Mode = .auto,
        maxTurns: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let inline = switch mode {
        case .auto: Terminal.isInteractive(environment: environment)
        case .plain: false
        case .inline: true
        }
        if inline {
            // NO_COLOR (no-color.org): set and not empty turns colour off.
            let color = (environment["NO_COLOR"] ?? "").isEmpty
            try await runInline(session, color: color, maxTurns: maxTurns)
        } else {
            await runPlain(session)
        }
    }

    @MainActor
    private static func runInline(_ session: ChatSession, color: Bool, maxTurns: Int?) async throws {
        let terminal = Terminal()
        let chat = InlineChat(session: session, terminal: terminal, color: color, maxTurns: maxTurns)
        let inputs = chat.inputs
        try terminal.start { signal in
            inputs.yield(signal == .resized ? .resize : .resume)
        }
        defer { terminal.stop() }
        await chat.run(keys: Terminal.keys())
    }

    private static func runPlain(_ session: ChatSession) async {
        let interactive = isatty(STDIN_FILENO) != 0
        // A pipe gets rows that are never wrapped.
        let columns = isatty(STDOUT_FILENO) != 0 ? Terminal.currentSize()?.columns ?? 80 : Int(Int32.max)
        let chat = PlainChat(session: session, layout: Layout(columns: columns), echoPrompts: !interactive) { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        await chat.run { readLine() }
    }
}

/// The inline chat: one main-actor loop over keys, agent events, spinner
/// ticks and resizes, drawing through `InlineScreen`.
///
/// Enter sends; Enter during a run queues the prompt for when it ends.
/// Esc or Ctrl-C interrupts a run (ending its stream cancels it) and keeps
/// the session. Ctrl-D on an empty prompt, or Ctrl-C twice, quits; so does
/// the end of input, once the current run is done.
@MainActor
final class InlineChat {
    enum Input: Sendable {
        case keys([Key])
        case keysEnded
        case agent(run: Int, AgentEvent)
        case runEnded(run: Int, error: String?)
        case tick
        case resize
        case resume
        case render
    }

    /// Everything the loop reacts to arrives here.
    nonisolated let inputs: AsyncStream<Input>.Continuation
    private let stream: AsyncStream<Input>

    private let session: ChatSession
    private let terminal: any TerminalIO
    private var screen: InlineScreen
    private var layout: Layout
    private var transcript: Transcript
    private var editor = LineEditor()

    /// Laid-out lines waiting for the next frame to put them in scrollback.
    private var committed: [StyledLine] = []
    private var current: (id: Int, task: Task<Void, Never>, started: ContinuousClock.Instant)?
    private var runs = 0
    private var queued: [String] = []
    private var ticker: Task<Void, Never>?
    private var spinnerFrame = 0
    /// Ctrl-C on an empty prompt was pressed once; a second press quits.
    private var quitArmed = false
    private var inputEnded = false
    private var quitting = false
    /// A model declined the last prompt and the user hasn't yet said whether
    /// to keep it (see `DeclinedRequest`). Queued prompts wait for the answer.
    private var unansweredRefusal: RefusalNotice?

    private let clock = ContinuousClock()
    private var lastFrame: ContinuousClock.Instant?
    private var renderScheduled = false
    /// Frames are at least this far apart, so bursts of events cost one write.
    static let frameInterval = Duration.milliseconds(33)
    static let tickInterval = Duration.milliseconds(125)

    init(session: ChatSession, terminal: any TerminalIO, color: Bool, maxTurns: Int? = nil) {
        self.session = session
        self.terminal = terminal
        self.screen = InlineScreen(color: color)
        self.layout = Layout(columns: terminal.size.columns)
        self.transcript = Transcript(maxTurns: maxTurns)
        (stream, inputs) = AsyncStream.makeStream()
    }

    func run(keys: AsyncStream<[Key]>) async {
        let inputs = self.inputs
        let reader = Task {
            for await batch in keys { inputs.yield(.keys(batch)) }
            inputs.yield(.keysEnded)
        }
        committed.append(layout.header(session.header))
        render()

        for await input in stream {
            handle(input)
            if quitting { break }
            requestRender()
        }

        reader.cancel()
        current?.task.cancel()
        ticker?.cancel()
        terminal.write(screen.clear(columns: terminal.size.columns, committed: committed))
        committed = []
    }

    // MARK: - Inputs

    private func handle(_ input: Input) {
        switch input {
        case .keys(let keys):
            for key in keys where !quitting { handle(key) }
        case .keysEnded:
            inputEnded = true
            if current == nil { quitting = true }
        case .agent(let id, let event):
            guard id == current?.id else { return }  // from a run already interrupted
            commit(transcript.reduce(event))
            if case .result(let result) = event, let refusal = result.refusal {
                unansweredRefusal = refusal
            }
        case .runEnded(let id, let error):
            guard id == current?.id else { return }
            // A stream that ends without a result was cut short.
            commit(error.map { transcript.fail($0) } ?? transcript.interrupt())
            finishRun()
        case .tick:
            spinnerFrame += 1
        case .resize:
            layout = Layout(columns: terminal.size.columns)
        case .resume:
            break  // the next frame redraws the live region
        case .render:
            renderScheduled = false
        }
    }

    private func handle(_ key: Key) {
        if let refusal = unansweredRefusal {
            answer(key, about: refusal)
            return
        }
        if key != .control("c") { quitArmed = false }
        switch key {
        case .control("c"):
            if current != nil {
                interrupt()
            } else if !editor.isEmpty {
                editor.clear()
            } else if quitArmed {
                quitting = true
            } else {
                quitArmed = true
            }
        case .escape:
            if current != nil { interrupt() } else { editor.clear() }
        case .control("d") where editor.isEmpty:
            if current == nil { quitting = true }
        case .control("l"):
            break  // every frame redraws the live region in full
        case .control("z"):
            terminal.write(screen.clear(columns: terminal.size.columns, committed: committed))
            committed = []
            terminal.suspend()
        default:
            guard case .submit(let text) = editor.apply(key) else { return }
            guard !text.allSatisfy(\.isWhitespace) else { return }
            if let command = SlashCommand(text) {
                run(command)
            } else if current == nil {
                start(text)
            } else {
                queued.append(text)
            }
        }
    }

    /// While the question about a declined prompt is up, only its answers
    /// count: Enter (or Esc, Ctrl-C) keeps the prompt, `r` removes it.
    /// Other keys are ignored so a prompt typed too early can't answer it.
    private func answer(_ key: Key, about refusal: RefusalNotice) {
        let remove = key == .text("r") || key == .text("R")
        let keep = key == .enter || key == .escape || key == .control("c")
        guard remove || keep else { return }
        unansweredRefusal = nil
        commit(DeclinedRequest.answer(remove: remove, notice: refusal, session: session))
        if current == nil { startNext() }
    }

    /// Commands run at once, even during a turn; they are not queued.
    private func run(_ command: SlashCommand) {
        let (blocks, effect) = command.perform(stats: transcript.stats, session: session, busy: current != nil)
        switch effect {
        case .none: break
        case .cleared: transcript = Transcript(maxTurns: transcript.maxTurns)
        case .quit: quitting = true
        }
        commit(blocks)
    }

    // MARK: - Runs

    private func start(_ prompt: String) {
        commit(transcript.submit(prompt))
        runs += 1
        let id = runs
        let events = session.send(prompt)
        let inputs = self.inputs
        let task = Task {
            do {
                for try await event in events { inputs.yield(.agent(run: id, event)) }
                inputs.yield(.runEnded(run: id, error: nil))
            } catch {
                inputs.yield(.runEnded(run: id, error: "\(error)"))
            }
        }
        current = (id, task, clock.now)
        ticker?.cancel()
        ticker = Task { [clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.tickInterval)
                inputs.yield(.tick)
            }
        }
    }

    /// Esc / Ctrl-C during a run: cancelling the task that drains the
    /// stream ends it, which cancels the loop. Events still on their way
    /// are dropped by run id.
    private func interrupt() {
        current?.task.cancel()
        commit(transcript.interrupt())
        finishRun()
    }

    private func finishRun() {
        current = nil
        ticker?.cancel()
        ticker = nil
        startNext()
    }

    private func startNext() {
        // Without input left there is no one to answer; the prompt stays.
        if unansweredRefusal != nil, !inputEnded { return }
        if !queued.isEmpty {
            start(queued.removeFirst())
        } else if inputEnded {
            quitting = true
        }
    }

    private func commit(_ blocks: [Block]) {
        committed += blocks.flatMap(layout.lines(for:))
    }

    // MARK: - Drawing

    private func requestRender() {
        guard !renderScheduled else { return }
        let now = clock.now
        if let lastFrame, now - lastFrame < Self.frameInterval {
            renderScheduled = true
            let wait = Self.frameInterval - (now - lastFrame)
            let inputs = self.inputs
            Task { [clock] in
                try? await clock.sleep(for: wait)
                inputs.yield(.render)
            }
            return
        }
        render()
    }

    private func render() {
        let size = terminal.size
        var live: [StyledLine] = []
        if let current {
            let elapsed = Int((clock.now - current.started).components.seconds)
            live = layout.status(transcript.live, frame: spinnerFrame, elapsedSeconds: elapsed, maxTurns: transcript.maxTurns)
        }
        for prompt in queued {
            live.append(layout.row(prompt, style: .dim, prefix: StyledSpan(" ⏎ queued  ", .dim)))
        }
        if let unansweredRefusal {
            let question = DeclinedRequest.question(unansweredRefusal)
            live += layout.paragraph(question, style: .color(.yellow), prefix: StyledSpan(" ? ", .color(.yellow)))
        }
        live = Array(live.suffix(max(size.rows / 2, 1)))

        // Borders and the footer take three rows; keep one spare so the
        // whole live region fits on screen and relative moves stay exact.
        let boxRows = min(max(size.rows - live.count - 4, 1), 12)
        let box = layout.promptBox(editor.text, cursor: editor.cursor, maxRows: boxRows)
        let cursor = InlineScreen.Cursor(row: live.count + box.cursor.row, column: box.cursor.column)
        live += box.lines
        live.append(footer())

        terminal.write(screen.frame(columns: size.columns, committed: committed, live: live, cursor: cursor))
        committed = []
        lastFrame = clock.now
    }

    private func footer() -> StyledLine {
        let hint: String? = if quitArmed {
            "press ctrl-c again to quit"
        } else if transcript.stats.usage.total == 0 {
            "/help for commands · alt-enter for a newline"
        } else {
            nil
        }
        if transcript.stats.usage.total == 0 {
            return layout.row(hint ?? "", style: .dim, prefix: StyledSpan(" "))
        }
        return layout.footer(transcript.stats, contextLimit: session.contextLimit, extra: hint)
    }
}
