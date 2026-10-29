import Synchronization
import AgentACP
import AgentCore
import AgentGateway
import AgentInstructions
import AgentJournal
import AgentLoop
import AgentMCP
import AgentTools
import AgentTUI
import Foundation

// MARK: - A simple session factory that composes the whole harness

/// The default `ACPSessionFactory`: composes the gateway, built-in tools, any
/// MCP servers requested by the client, and the system prompt (Nawa's
/// default, SOUL.md, AGENTS.md and skills) into a ready-to-run `AgentLoop`, recorded in a journal in
/// `sessions` so `session/load` can bring it back.
///
/// The gateway and the built-in tools are made per session from the
/// session's working directory, because `nawa config` stores providers per
/// directory and one ACP process may serve sessions in several projects.
public struct HarnessSessionFactory: ACPSessionFactory {
    public let gatewayForDirectory: @Sendable (URL) throws -> any LanguageModel
    /// The settings a session in a directory runs with: its saved settings
    /// and the environment (`Settings.resolved`). They decide the system
    /// prompt (skills) and, unless `loopOptions` was given, the loop options.
    public let settingsForDirectory: @Sendable (URL) -> DirectorySettings
    /// Fixed loop options for every session; nil builds them per directory
    /// from `settingsForDirectory`.
    public let loopOptions: LoopOptions?
    /// Where journals go; nil records nothing and can't restore.
    public let sessions: SessionStore?
    /// `acp` or `serve`, for the journal.
    public let mode: String

    /// Past this many MCP tools, they are offered through `tool_search` and
    /// `call_tool` instead of one definition each (see DeferredTools.swift).
    static let maxDirectMCPTools = 10

    public init(
        gatewayForDirectory: @escaping @Sendable (URL) throws -> any LanguageModel,
        loopOptions: LoopOptions? = nil,
        settingsForDirectory: @escaping @Sendable (URL) -> DirectorySettings = { _ in DirectorySettings() },
        sessions: SessionStore? = nil,
        mode: String = "acp"
    ) {
        self.gatewayForDirectory = gatewayForDirectory
        self.loopOptions = loopOptions
        self.settingsForDirectory = settingsForDirectory
        self.sessions = sessions
        self.mode = mode
    }

    public func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        let (gateway, tools, systemPrompt, options) = try await parts(cwd: cwd, mcpServers: mcpServers)
        let journal = sessions.map { AgentCLI.journal(at: $0.newJournalURL(sessionID: sessionID), mode: mode) }
        return AgentLoop(
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: options,
            cwd: cwd,
            sessionID: sessionID,
            journal: journal
        )
    }

    /// The session keeps the directory it was started in, whatever `cwd`
    /// the client sends with `session/load`.
    public func restoreLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop? {
        guard let url = sessions?.journalURL(forSession: sessionID),
              let state = JournalReader.read(url).replay(),
              state.sessionID == sessionID
        else { return nil }
        let (gateway, tools, systemPrompt, options) = try await parts(cwd: state.cwd, mcpServers: mcpServers)
        return AgentLoop(
            restoring: state,
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: options,
            journal: AgentCLI.journal(at: url, mode: mode)
        )
    }

    /// What a session in `cwd` runs with: its directory's gateway, the
    /// built-in and MCP tools, its system prompt (see `SystemPrompt`), and
    /// its loop options.
    private func parts(cwd: String, mcpServers: [MCPServerConfig]) async throws -> (any LanguageModel, ToolRegistry, String?, LoopOptions) {
        let directory = URL(fileURLWithPath: cwd)
        let settings = settingsForDirectory(directory)
        let gateway = try gatewayForDirectory(directory)
        var tools = ToolRegistry(AgentCLI.builtInTools(workingDirectory: directory))

        // Connect any MCP servers the client requested for this session.
        var mcpTools: [any Tool] = []
        for config in mcpServers {
            let client = MCPClient(config: config)
            do {
                try await client.start()
            } catch {
                // A failing MCP server shouldn't sink the session; report and skip.
                continue
            }
            // Expose the MCP server's tools under prefixed names to avoid clashes.
            for tool in await client.tools {
                mcpTools.append(PrefixedTool(prefix: "\(config.name)__", wrapped: client, remote: tool))
            }
        }
        if mcpTools.count > Self.maxDirectMCPTools {
            tools.register(ToolSearchTool(tools: mcpTools))
            tools.register(CallToolTool(tools: mcpTools))
        } else {
            tools.register(contentsOf: mcpTools)
        }

        // The default prompt, SOUL.md, AGENTS.md and skills for the session's directory.
        let prompt = AgentCLI.systemPrompt(for: directory, settings: settings)
        tools.register(contentsOf: prompt.tools)
        return (gateway, tools, prompt.text, loopOptions ?? AgentCLI.defaultLoopOptions(settings: settings.loop))
    }
}

/// Wraps an MCP server's tool so it can be called through the harness `Tool`
/// protocol, with a name prefix to avoid clashes across MCP servers.
public struct PrefixedTool: Tool {
    public let prefix: String
    public let wrapped: MCPClient
    public let remote: MCPToolDefinition

    public var definition: ToolDefinition {
        ToolDefinition(
            name: prefix + remote.name,
            description: remote.description ?? "(MCP tool \(remote.name))",
            parameters: remote.inputSchema ?? .object(["type": .string("object")])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        return try await wrapped.callTool(name: remote.name, arguments: arguments)
    }
}

// MARK: - Entry point

@main
struct AgentCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("nawa: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "serve"

        // Process-wide settings (session recording) come from the directory
        // nawa starts in; each session's own from its directory.
        let startSettings = Settings.resolved(for: WorkingDirectory.defaultURL)
        if let problem = Settings.problem(with: startSettings) {
            FileHandle.standardError.write(Data("nawa: \(problem)\n".utf8))
        }
        // Every session is recorded unless the `sessions` setting is off (proposal 0005).
        let sessions = sessionStore(startSettings)
        func sessionFactory(mode: String) -> HarnessSessionFactory {
            HarnessSessionFactory(
                gatewayForDirectory: { directory in try resolveGateway(directory: directory) },
                settingsForDirectory: { directory in Settings.resolved(for: directory) },
                sessions: sessions,
                mode: mode
            )
        }
        let capabilities = ACPCapabilities(loadSession: sessions != nil)

        // Waku launches the agent as a Kimi Code CLI and generates commit
        // messages with `--prompt …` (see WakuCompatibility.swift). Only
        // flags, no subcommand: `nawa config --prompt` is not a one-shot.
        if command.hasPrefix("--"), args.contains("--prompt") {
            try await WakuCompatibility.oneShotPrompt(arguments: args, sessions: sessions)
            return
        }

        switch command {
        case "--version", "version":
            print("nawa \(ACPServerInfo.nawa.version)")
        case "serve":
            let configuration = ACPServerConfiguration(
                capabilities: capabilities,
                idleSessionTimeout: sessions == nil ? nil : idleSessionTimeout(minutes: startSettings.sessionIdleMinutes)
            )
            let server = ACPServer(configuration: configuration, factory: sessionFactory(mode: "serve"))
            let app = server.buildApplication()
            print("ACP server listening on http://127.0.0.1:7878/acp")
            try await app.runService()
        case "acp":
            try await ACPStdioTransport(factory: sessionFactory(mode: "acp"), capabilities: capabilities).run()
        case "provider":
            try await WakuCompatibility.providerCommand(arguments: Array(args.dropFirst()))
        case "repl":
            let replArgs = Array(args.dropFirst())
            let plain = replArgs.contains("--plain")
            let resume = try resumedSession(arguments: replArgs, sessions: sessions)
            // A resumed session runs where it was recorded, with that directory's provider.
            let directory = resume.map { URL(fileURLWithPath: $0.state.cwd) } ?? WorkingDirectory.defaultURL
            let gateway = try resolveGateway(directory: directory)
            try await repl(gateway: gateway, mode: plain ? .plain : .auto, directory: directory, sessions: sessions, resume: resume)
        case "config":
            try await ConfigCommand.run(arguments: Array(args.dropFirst()))
        case "sessions":
            try SessionsCommand.run(arguments: Array(args.dropFirst()), sessions: sessions)
        case "prompt":
            // What a session started here would tell the model, to check
            // SOUL.md, AGENTS.md and skills without starting one.
            let directory = args.count > 1 ? URL(fileURLWithPath: args[1]) : WorkingDirectory.defaultURL
            let prompt = systemPrompt(for: directory, settings: Settings.resolved(for: directory))
            print(SystemPrompt.composed(prompt.text))
            let extraTools = prompt.tools.map(\.definition.name).joined(separator: ", ")
            let summary = "\(SystemPrompt.composed(prompt.text).count) chars, \(prompt.skills.skills.count) skills" + (extraTools.isEmpty ? "" : ", adds \(extraTools)")
            FileHandle.standardError.write(Data("\n[\(summary)]\n".utf8))
        default:
            print("Usage: nawa [serve|acp|repl|config|sessions|prompt|provider list]")
            print("  serve  — start the ACP server (streamable HTTP + WebSocket) on :7878")
            print("  acp    — speak ACP over stdio (for editors and Waku that launch the agent)")
            print("  repl [--plain] [--resume [id]] — chat with the agent in the terminal (--plain: line mode;")
            print("         --resume: go on with a recorded session, by default this directory's newest; /help inside lists commands)")
            print("  sessions list|show|path|prune — the recorded sessions (nawa config set sessions off turns recording off)")
            print("  prompt [dir] — print the system prompt a session in this directory would get")
            print("  config [settings|set|unset] — configure providers (OpenAI-compatible or Anthropic) and settings for the current directory")
            print("  provider list [--json] — list the active provider's models")
        }
    }

    /// A journal file for one session. A journal that can't be written
    /// says so once on stderr (never stdout: in `acp` mode that is the
    /// protocol) and stops; the session goes on.
    static func journal(at url: URL, mode: String) -> JournalFile {
        let origin = JournalOrigin(mode: mode, nawaVersion: ACPServerInfo.nawa.version)
        return JournalFile(url: url, origin: origin) { problem in
            FileHandle.standardError.write(Data("nawa: \(problem)\n".utf8))
        }
    }

    /// How long a `serve` session may sit without a prompt before it is
    /// unloaded: `NAWA_SESSION_IDLE_MINUTES`, 30 by default.
    static func idleSessionTimeout(minutes: Double?) -> Duration {
        .seconds((minutes ?? 30) * 60)
    }

    /// Where sessions are recorded: nil when the `sessions` setting is off,
    /// else `sessions_dir`, else the default (`SessionStore.fromEnvironment`
    /// without the variables the settings already read).
    static func sessionStore(_ settings: DirectorySettings, environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionStore? {
        if settings.sessions == false { return nil }
        if let directory = settings.sessionsDirectory {
            return SessionStore(directory: URL(fileURLWithPath: directory))
        }
        var defaultsOnly = environment
        defaultsOnly["NAWA_SESSIONS"] = nil
        defaultsOnly["NAWA_SESSIONS_DIR"] = nil
        return SessionStore.fromEnvironment(defaultsOnly)
    }

    /// The system prompt for a session in `directory`, with its skills settings.
    static func systemPrompt(for directory: URL, settings: DirectorySettings) -> SystemPrompt {
        SystemPrompt.load(
            for: directory,
            skills: settings.skills ?? true,
            projectSkills: settings.projectSkills ?? true
        )
    }

    /// The session `repl --resume [id]` goes on with: the one named (from
    /// any mode), or the newest repl session in this directory. Nil without
    /// `--resume`.
    static func resumedSession(
        arguments: [String],
        sessions: SessionStore?,
        directory: URL = WorkingDirectory.defaultURL
    ) throws -> (state: SessionState, url: URL)? {
        guard let flag = arguments.firstIndex(of: "--resume") else { return nil }
        guard let sessions else { throw CLIError.resumeWithoutSessions }
        let next = arguments.index(after: flag)
        let requestedID = next < arguments.endIndex && !arguments[next].hasPrefix("--") ? arguments[next] : nil

        let found: URL?
        if let requestedID {
            found = sessions.journalURL(forSession: requestedID)
        } else {
            found = sessions.newestSession(inDirectory: directory.path, mode: "repl")
        }
        guard let url = found, let state = JournalReader.read(url).replay() else {
            throw CLIError.noSessionToResume(requestedID)
        }
        return (state, url)
    }

    static func builtInTools(workingDirectory: URL) -> [any Tool] {
        [
            CurrentTimeTool(),
            ShellTool(workingDirectory: workingDirectory),
            ReadFileTool(workingDirectory: workingDirectory),
            EditFileTool(workingDirectory: workingDirectory),
            SearchTool(workingDirectory: workingDirectory),
            ListFilesTool(workingDirectory: workingDirectory),
        ]
    }

    /// Token-saving defaults for `repl`, `acp` and `serve`, with `settings`
    /// (the `nawa config set` ones, `LoopSettings`) applied over them.
    static func defaultLoopOptions(settings: LoopSettings = LoopSettings()) -> LoopOptions {
        let defaults = LoopOptions(
            keepToolResults: 20,
            // ~60K tokens of tool output; clearing goes back to half of it.
            keepToolResultChars: 240_000,
            // 120K: past it, on most models every request costs more than a
            // summary saves. `compact_at` gives large-window models more room.
            compaction: Compaction(atContextTokens: 120_000, keepRecentMessages: 20),
            subAgents: true
        )
        return defaults.applying(settings)
    }

    /// Build the gateway for this run. Precedence:
    /// 1. `NAWA_GATEWAY_URL` / `NAWA_GATEWAY_API_KEY` / `NAWA_MODEL` env vars (explicit override);
    ///    `NAWA_GATEWAY_API=anthropic` switches it from the OpenAI wire API to Anthropic's.
    /// 2. The per-directory configuration saved by `nawa config` for the current directory.
    /// 3. `NAWA_GATEWAY_CONFIG` or a `Gateways.json` in the current directory.
    /// 4. OpenAI with `OPENAI_API_KEY`.
    static func resolveGateway(
        directory cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> Gateway {
        let env = ProcessInfo.processInfo.environment

        if let baseURL = env["NAWA_GATEWAY_URL"] {
            return try envGateway(baseURL: baseURL, env: env)
        }

        let store = try AgentConfigStore.load()
        if let config = store.gatewayConfig(for: cwd), !config.providers.isEmpty {
            return config.withEnvironmentDefaults(env).makeGateway()
        }

        let fileConfig = try GatewayConfig.loadFromEnvironmentOrFile()
        if !fileConfig.providers.isEmpty {
            return fileConfig.withEnvironmentDefaults(env).makeGateway()
        }

        return try envGateway(baseURL: "https://api.openai.com/v1", env: env)
    }

    static func envGateway(baseURL: String, env: [String: String]) throws -> Gateway {
        var api = ProviderAPI.openAI
        if let requested = env["NAWA_GATEWAY_API"] {
            guard let parsed = ProviderAPI(rawValue: requested.lowercased()) else {
                throw CLIError.unknownAPI(requested)
            }
            api = parsed
        }
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else {
            throw CLIError.invalidGatewayURL(baseURL)
        }
        let fallbackKeyVariable = api == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        let provider = ProviderConfig(
            name: "default",
            api: api,
            baseURL: url,
            apiKey: env["NAWA_GATEWAY_API_KEY"] ?? env[fallbackKeyVariable],
            model: env["NAWA_MODEL"]
        ).withEnvironmentDefaults(env)
        return Gateway(providers: [provider], activeProviderName: "default")
    }

    /// The chat in the terminal. Settings come from `directory`'s saved
    /// settings plus the environment (`Settings.resolved`), read again
    /// for every new conversation; `/config` changes them while it runs.
    static func repl(
        gateway: Gateway,
        mode: ChatApp.Mode = .auto,
        directory: URL = WorkingDirectory.defaultURL,
        sessions: SessionStore? = nil,
        resume: (state: SessionState, url: URL)? = nil
    ) async throws {
        // Everything runs in `directory`: a resumed session's, which can
        // differ from where `nawa repl` was started.
        struct Conversation {
            var options: LoopOptions
            var prompt: SystemPrompt
            var tools: ToolRegistry
        }
        // What a new conversation starts with. Read again on `/clear`, so
        // settings that change the system prompt (skills) apply then.
        @Sendable func conversationSettings() -> Conversation {
            let settings = Settings.resolved(for: directory)
            let prompt = systemPrompt(for: directory, settings: settings)
            return Conversation(
                options: defaultLoopOptions(settings: settings.loop),
                prompt: prompt,
                tools: ToolRegistry(builtInTools(workingDirectory: directory) + prompt.tools)
            )
        }
        // No turn cap, like Claude Code: the loop check (LoopOptions.loopCheckAfterTurns)
        // stops a stuck run, and max_budget_usd caps the spend.
        @Sendable func makeLoop() -> AgentLoop {
            let sessionID = UUID().uuidString
            let conversation = conversationSettings()
            return AgentLoop(
                gateway: gateway,
                tools: conversation.tools,
                systemPrompt: conversation.prompt.text,
                options: conversation.options,
                cwd: directory.path,
                sessionID: sessionID,
                journal: sessions.map { journal(at: $0.newJournalURL(sessionID: sessionID), mode: "repl") }
            )
        }
        let start = conversationSettings()
        let firstLoop: AgentLoop
        if let resume {
            firstLoop = AgentLoop(
                restoring: resume.state,
                gateway: gateway,
                tools: start.tools,
                systemPrompt: start.prompt.text,
                options: start.options,
                journal: journal(at: resume.url, mode: "repl")
            )
        } else {
            firstLoop = makeLoop()
        }
        // `/clear` swaps in a fresh loop: a new conversation, same tools.
        let loop = Mutex(firstLoop)
        let session = ChatSession(
            header: SessionHeader(
                provider: gateway.activeProvider?.name,
                model: gateway.activeProvider?.model,
                directory: displayPath(directory),
                instructionsFile: start.prompt.instructions?.nearest.lastPathComponent,
                skillCount: start.prompt.skills.skills.count
            ),
            tools: loop.withLock { $0.toolDefinitions.map(\.name) },
            history: resume?.state.messages ?? [],
            send: { prompt in loop.withLock { $0 }.run(prompt: prompt, continuing: true) },
            reset: { loop.withLock { $0 = makeLoop() } },
            removeDeclinedRequest: { loop.withLock { $0 }.removeDeclinedRequest() },
            liveContextLimit: { loop.withLock { $0 }.options.compaction?.atContextTokens },
            configure: { arguments in
                let lines = Settings.command(arguments, directory: directory, inSession: true)
                // Apply what takes effect now to the running conversation.
                let options = defaultLoopOptions(settings: Settings.resolved(for: directory).loop)
                loop.withLock { $0 }.options = options
                return lines
            }
        )
        try await ChatApp.run(session, mode: mode, maxTurns: start.options.maxTurns)
    }

    /// `~/src/nawa` for a directory under the home directory.
    static func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum CLIError: Error, LocalizedError {
    case unknownAPI(String)
    case invalidGatewayURL(String)
    case resumeWithoutSessions
    case noSessionToResume(String?)

    var errorDescription: String? {
        switch self {
        case .unknownAPI(let value):
            let known = ProviderAPI.allCases.map(\.rawValue).joined(separator: ", ")
            return "NAWA_GATEWAY_API=\(value) is not one of: \(known)"
        case .invalidGatewayURL(let value):
            return "NAWA_GATEWAY_URL=\(value) is not an absolute URL"
        case .resumeWithoutSessions:
            return "--resume needs recorded sessions, but the sessions setting is off"
        case .noSessionToResume(let id?):
            return "no recorded session \(id) (nawa sessions list --all shows them)"
        case .noSessionToResume(nil):
            return "no recorded session in this directory (nawa sessions list shows them)"
        }
    }
}
