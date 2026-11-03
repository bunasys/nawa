import AgentCore

/// The chat's own commands: a prompt whose first word is `/name`.
///
/// Both the inline UI and plain mode run them through `perform`, so they
/// behave the same everywhere. A first word with a second `/` in it
/// (`/usr/bin/env is missing`) is a path, and the line goes to the agent.
public enum SlashCommand: Sendable, Hashable {
    case help
    case clear
    case cost
    case tools
    /// `/config`, with the words after it (`set compact_at 200k`).
    case config([String])
    /// `/effort`, `/effort high`, `/effort default`: a shortcut for the
    /// `effort` setting.
    case effort([String])
    case exit
    /// `/name` that isn't a command.
    case unknown(String)
    /// A command other than `/config` with words after it (`/clear all`):
    /// warned about rather than run or sent, so neither happens by surprise.
    case unexpectedWords(String)

    /// Names and one-line summaries, in `/help` order.
    static let all: [(command: SlashCommand, name: String, summary: String)] = [
        (.help, "/help", "this list"),
        (.clear, "/clear", "start a new conversation"),
        (.cost, "/cost", "tokens and cost so far"),
        (.tools, "/tools", "the tools the agent can use"),
        (.config([]), "/config", "list settings; /config set <key> <value>, /config unset <key>"),
        (.effort([]), "/effort", "how hard the model thinks: /effort high, /effort default"),
        (.exit, "/exit", "quit (also ctrl-d)"),
    ]

    /// The command `text` asks for, or nil when it is a prompt. Only a
    /// single line can be a command: several lines are a prompt, even when
    /// the first starts with `/`.
    public init?(_ text: String) {
        let trimmed = text.trimmingTrailingWhitespace.drop { $0.isWhitespace }
        guard trimmed.first == "/", !trimmed.contains(where: \.isNewline) else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = words[0]
        guard name.dropFirst().contains("/") == false, name.count > 1 else { return nil }
        let arguments = Array(words.dropFirst())
        switch name.lowercased() {
        case "/config":
            self = .config(arguments)
            return
        case "/effort":
            self = .effort(arguments)
            return
        default:
            break
        }
        guard let known = Self.all.first(where: { $0.name == name.lowercased() }) else {
            self = .unknown(name)
            return
        }
        self = arguments.isEmpty ? known.command : .unexpectedWords(known.name)
    }

    /// What running a command changes besides the committed blocks.
    public enum Effect: Sendable, Hashable {
        case none
        /// The conversation was reset: start a fresh `Transcript`.
        case cleared
        case quit
    }

    /// Runs the command: what to commit, and what the caller must do.
    /// `busy` means a run is in progress, which `/clear` won't cut short.
    public func perform(
        stats: SessionStats,
        session: ChatSession,
        busy: Bool
    ) -> (blocks: [Block], effect: Effect) {
        switch self {
        case .help:
            let width = Self.all.map(\.name.count).max() ?? 0
            let rows = Self.all.map { $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
            return (rows.map(Block.note) + [.note("alt-enter or ctrl-j for a newline · esc interrupts a turn")], .none)
        case .clear:
            if busy { return ([.warning("/clear waits for the turn to end; esc interrupts it")], .none) }
            session.reset()
            return ([.note("new conversation")], .cleared)
        case .cost:
            return ([.note(Self.costReport(stats, contextLimit: session.contextLimit))], .none)
        case .tools:
            let names = session.tools
            return ([.note(names.isEmpty ? "no tools" : "\(names.count) tools: " + names.joined(separator: ", "))], .none)
        case .config(let arguments):
            guard let configure = session.configure else {
                return ([.warning("this session has no settings to change")], .none)
            }
            return (configure(arguments).map(Block.note), .none)
        case .effort(let arguments):
            guard let configure = session.configure else {
                return ([.warning("this session has no settings to change")], .none)
            }
            return (configure(Self.effortConfigArguments(arguments)).map(Block.note), .none)
        case .exit:
            return ([], .quit)
        case .unknown(let name):
            return ([.warning("unknown command \(name); /help lists them")], .none)
        case .unexpectedWords(let name):
            return ([.warning("\(name) takes nothing after it; nothing was run or sent")], .none)
        }
    }

    /// The `/config` words `/effort` stands for. `default` (or `unset`)
    /// goes back to the provider's effort.
    static func effortConfigArguments(_ arguments: [String]) -> [String] {
        guard let level = arguments.first else { return ["get", "effort"] }
        let backToDefault = arguments.count == 1 && ["default", "unset"].contains(level.lowercased())
        if backToDefault { return ["unset", "effort"] }
        return ["set", "effort"] + arguments
    }

    /// `12.4k tokens: 2.1k input, 9.8k cached, 500 output · $0.012 · context 9%`.
    static func costReport(_ stats: SessionStats, contextLimit: Int?) -> String {
        let usage = stats.usage
        guard usage.total > 0 else { return "nothing spent yet" }
        let kinds = [
            (usage.inputTokens, "input"),
            (usage.cacheReadTokens, "cached"),
            (usage.cacheWriteTokens, "written to the cache"),
            (usage.outputTokens, "output"),
        ].filter { $0.0 > 0 }.map { "\(Format.tokens($0.0)) \($0.1)" }
        var parts = ["\(Format.tokens(usage.total)) tokens: " + kinds.joined(separator: ", ")]
        parts.append(stats.cost.map(Format.cost) ?? "no cost estimate without prices (/config set price <input,output>)")
        if let contextLimit, contextLimit > 0 {
            let percent = min(stats.contextTokens * 100 / contextLimit, 999)
            parts.append("context \(Format.tokens(stats.contextTokens))/\(Format.tokens(contextLimit)) (\(percent)%)")
        }
        return parts.joined(separator: " · ")
    }
}
