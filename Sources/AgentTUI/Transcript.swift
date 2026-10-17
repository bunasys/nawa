import AgentCore

/// A finished piece of the conversation. Once committed it is written to
/// scrollback and never changed, which keeps the terminal append-only.
public enum Block: Sendable, Hashable {
    /// What the user sent: `› text`.
    case prompt(String)
    /// The model's text for one turn: `● text`.
    case assistant(String)
    /// A tool call with its outcome (and, for `task`, the sub-agent's steps).
    case tool(ToolBlock)
    /// A quiet status line from the loop: `· text`.
    case note(String)
    /// Something went wrong or was cut short: `⚠ text`.
    case warning(String)
}

public struct ToolBlock: Sendable, Hashable {
    public var label: ToolLabel
    /// Nil when the call never finished (the turn was interrupted).
    public var summary: ResultSummary?
    public var subAgent: SubAgentTrace?

    public init(label: ToolLabel, summary: ResultSummary?, subAgent: SubAgentTrace? = nil) {
        self.label = label
        self.summary = summary
        self.subAgent = subAgent
    }
}

/// What a sub-agent did while it ran a `task` call.
public struct SubAgentTrace: Sendable, Hashable {
    public enum Step: Sendable, Hashable {
        case text(String)
        case tool(ToolLabel)
    }

    /// The model it ran on; nil when the gateway picked.
    public var model: String?
    public var steps: [Step] = []
    /// `done · 3 turns · 8.2k tokens · $0.0040`, once it has finished.
    public var outcome: String?
    public var failed = false

    public init(model: String?) { self.model = model }
}

/// What is happening right now: drawn in the live region, never committed.
public struct LiveState: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case idle
        /// Waiting for the model's first words.
        case waiting
        /// The model is streaming its reasoning.
        case thinking
        /// The model is streaming its reply.
        case writing
        /// The model is writing a tool call's arguments.
        case preparingTool
        /// Waiting for the tools in `running`.
        case runningTools
    }

    /// The model call being streamed (proposal 0004). Only the newest part
    /// of each text is kept: the preview shows a few rows and the whole
    /// reply arrives with the turn.
    public struct InFlight: Sendable, Hashable {
        /// Characters of reasoning and of text kept for the preview.
        public static let keep = 2048

        public var thinking = ""
        public var text = ""
        /// The tool call whose arguments are being written.
        public var preparing: ToolLabel?
        /// Everything streamed in this call, for the `~N tokens` estimate.
        public var characters = 0
        /// When reasoning started arriving, and when the model moved on.
        var thinkingStarted: ContinuousClock.Instant?
        var thinkingEnded: ContinuousClock.Instant?

        public init() {}

        mutating func think(_ delta: String, at now: ContinuousClock.Instant) {
            if thinkingStarted == nil { thinkingStarted = now }
            thinkingEnded = nil
            Self.append(delta, to: &thinking)
            characters += delta.count
        }

        mutating func write(_ delta: String, at now: ContinuousClock.Instant) {
            stopThinking(at: now)
            Self.append(delta, to: &text)
            characters += delta.count
        }

        mutating func stopThinking(at now: ContinuousClock.Instant) {
            if thinkingStarted != nil, thinkingEnded == nil { thinkingEnded = now }
        }

        /// Seconds spent reasoning, once the model has shown some.
        func thoughtSeconds(at now: ContinuousClock.Instant) -> Int? {
            guard let start = thinkingStarted else { return nil }
            let seconds = Int(((thinkingEnded ?? now) - start).components.seconds)
            return max(seconds, 1)
        }

        private static func append(_ delta: String, to text: inout String) {
            text += delta
            // Trim in batches so a long stream isn't re-cut on every delta.
            if text.utf8.count > keep * 8 || text.count > keep * 2 { text = String(text.suffix(keep)) }
        }
    }

    public struct RunningTool: Sendable, Hashable {
        public var id: String
        public var label: ToolLabel
        public var subAgent: SubAgentTrace?
    }

    public var phase: Phase = .idle
    /// The model call this run is on, counted from 1.
    public var turn = 0
    /// Calls of the current turn still waiting for their result, in call order.
    public var running: [RunningTool] = []
    /// The model call being streamed; empty between calls.
    public var inFlight = InFlight()

    public var isBusy: Bool { phase != .idle }
}

/// Session totals for the footer.
public struct SessionStats: Sendable, Hashable {
    public var usage: Usage = .zero
    public var cost: Double?
    /// Size of the conversation at the last model call.
    public var contextTokens = 0

    public init() {}
}

/// Turns `AgentEvent`s into committed `Block`s plus the live state.
///
/// A pure reducer: no terminal, and the time comes in with each event.
/// Both the inline UI and plain mode drive one, so there is a single
/// formatting path.
public struct Transcript: Sendable {
    public private(set) var live = LiveState()
    public private(set) var stats = SessionStats()
    /// The loop's per-prompt turn cap, shown as `turn 3/20`.
    public let maxTurns: Int?

    public init(maxTurns: Int? = nil) { self.maxTurns = maxTurns }

    /// The user sent `prompt`; a run starts.
    public mutating func submit(_ prompt: String) -> [Block] {
        live = LiveState(phase: .waiting, turn: 1)
        return [.prompt(prompt)]
    }

    /// `now` times the reasoning for the `thought for 4s` note.
    public mutating func reduce(_ event: AgentEvent, now: ContinuousClock.Instant = .now) -> [Block] {
        switch event {
        case .initEvent, .toolResult:
            // The header is printed at startup; `.toolResults` carries the
            // same results as a batch.
            return []

        case .stream(let update):
            // Drawn live only: the whole turn arrives with `.assistant`.
            switch update {
            case .thinkingDelta(let delta):
                live.inFlight.think(delta, at: now)
                live.phase = .thinking
            case .textDelta(let delta):
                live.inFlight.write(delta, at: now)
                live.phase = .writing
            case .toolCallStart(let call):
                live.inFlight.stopThinking(at: now)
                live.inFlight.preparing = ToolLabel(call)
                live.phase = .preparingTool
            case .toolCallArgumentsDelta(_, let json):
                live.inFlight.characters += json.count
            }
            return []

        case .assistant(let update):
            stats.usage = update.sessionUsage
            stats.cost = update.sessionCost
            stats.contextTokens = update.usage.total
            live.running = update.toolCalls.map { LiveState.RunningTool(id: $0.id, label: ToolLabel($0)) }
            live.phase = update.toolCalls.isEmpty ? .idle : .runningTools
            var blocks: [Block] = []
            if let seconds = live.inFlight.thoughtSeconds(at: now) {
                blocks.append(.note("thought for \(Layout.elapsed(seconds))"))
            }
            live.inFlight = LiveState.InFlight()
            let text = update.text.trimmingTrailingWhitespace
            if !text.isEmpty { blocks.append(.assistant(text)) }
            return blocks

        case .subAgent(let update):
            guard let index = live.running.firstIndex(where: { $0.id == update.callID }) else { return [] }
            var trace = live.running[index].subAgent ?? SubAgentTrace(model: update.model)
            trace.record(update.event)
            live.running[index].subAgent = trace
            return []

        case .toolResults(let results):
            var blocks: [Block] = []
            for result in results {
                let running = live.running.first { $0.id == result.callID }
                live.running.removeAll { $0.id == result.callID }
                blocks.append(.tool(ToolBlock(
                    label: running?.label ?? ToolLabel(name: result.name, detail: ""),
                    summary: ResultSummary(result),
                    subAgent: running?.subAgent
                )))
            }
            // Calls the loop dropped without a result are not left spinning.
            blocks += flushRunning()
            live.phase = .waiting
            live.turn += 1
            return blocks

        case .informational(let text):
            return [.note(text)]

        case .result(let result):
            var blocks = flushRunning()
            live.phase = .idle
            switch result.kind {
            case .success:
                break
            case .errorMaxTurns:
                blocks.append(.note("stopped after \(result.numTurns) turns; send \"continue\" to keep going"))
            case .errorMaxBudgetUSD:
                let spent = result.costEstimate.map { " (\(Format.cost($0)))" } ?? ""
                blocks.append(.warning("stopped: the budget is spent\(spent)"))
            case .errorDuringExecution:
                blocks.append(.warning("\(result.kind.rawValue): \(result.errorMessage ?? "unknown error")"))
            }
            return blocks
        }
    }

    /// The user interrupted the run, or its stream ended without a result.
    public mutating func interrupt() -> [Block] {
        guard live.isBusy else { return [] }
        let blocks = flushRunning() + [.warning("interrupted")]
        live.phase = .idle
        live.inFlight = LiveState.InFlight()
        return blocks
    }

    /// The stream failed outright (not a loop error, which arrives as a result).
    public mutating func fail(_ message: String) -> [Block] {
        let blocks = flushRunning() + [.warning(message)]
        live.phase = .idle
        live.inFlight = LiveState.InFlight()
        return blocks
    }

    /// Commits calls still running, marked as unfinished.
    private mutating func flushRunning() -> [Block] {
        defer { live.running = [] }
        return live.running.map { .tool(ToolBlock(label: $0.label, summary: nil, subAgent: $0.subAgent)) }
    }
}

extension SubAgentTrace {
    mutating func record(_ event: AgentEvent) {
        switch event {
        case .assistant(let turn):
            let text = turn.text.trimmingTrailingWhitespace
            if !text.isEmpty { steps.append(.text(text)) }
            steps += turn.toolCalls.map { .tool(ToolLabel($0)) }
        case .result(let result):
            failed = !result.isSuccess
            var parts = [result.isSuccess ? "done" : "stopped: \(result.kind.rawValue)"]
            parts.append(result.numTurns == 1 ? "1 turn" : "\(result.numTurns) turns")
            parts.append("\(Format.tokens(result.usage.total)) tokens")
            if let cost = result.costEstimate { parts.append(Format.cost(cost)) }
            outcome = parts.joined(separator: " · ")
        default:
            break
        }
    }
}

/// Short numbers for status lines.
public enum Format {
    /// `950`, `8.2k`, `48.1k`, `120k`, `1.2M`.
    public static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            var text = fixed(value, digits: value < 99.95 ? 1 : 0)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + unit
        }
        if count < 1000 { return "\(count)" }
        if count < 999_500 { return short(Double(count) / 1000, "k") }
        return short(Double(count) / 1_000_000, "M")
    }

    /// `$0.0040`, `$0.031`, `$1.25`.
    public static func cost(_ dollars: Double) -> String {
        "$" + fixed(dollars, digits: dollars < 0.00995 ? 4 : dollars < 0.9995 ? 3 : 2)
    }

    /// `value` rounded to `digits` decimals, without Foundation's `String(format:)`.
    static func fixed(_ value: Double, digits: Int) -> String {
        var scale = 1
        for _ in 0..<digits { scale *= 10 }
        let scaled = Int((abs(value) * Double(scale)).rounded())
        let sign = value < 0 && scaled != 0 ? "-" : ""
        guard digits > 0 else { return sign + "\(scaled)" }
        let fraction = String(scaled % scale)
        return sign + "\(scaled / scale)." + String(repeating: "0", count: digits - fraction.count) + fraction
    }
}

extension String {
    var trimmingTrailingWhitespace: String {
        var text = Substring(self)
        while text.last?.isWhitespace == true { text.removeLast() }
        while text.first?.isNewline == true { text.removeFirst() }
        return String(text)
    }
}
