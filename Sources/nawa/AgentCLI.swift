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
    /// the client sends with `session/load`. Throws when another nawa has
    /// the session open or its journal is damaged.
    public func restoreLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop? {
        guard let url = sessions?.journalURL(forSession: sessionID),
              let reopened = try AgentCLI.reopenSession(at: url, mode: mode),
              reopened.state.sessionID == sessionID
        else { return nil }
        let (gateway, tools, systemPrompt, options) = try await parts(cwd: reopened.state.cwd, mcpServers: mcpServers)
        return AgentLoop(
            restoring: reopened.state,
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: options,
            journal: reopened.journal
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
        for var config in mcpServers {
            // Relative paths the server uses mean the session's directory,
            // not wherever nawa was started.
            config.workingDirectory = config.workingDirectory ?? cwd
            let client = MCPClient(config: config)
            do {
                try await client.start()
            } catch {
                // A failing MCP server shouldn't sink the session: say so on
                // stderr (in `acp` mode stdout is the protocol), take down
                // whatever it started, and go on without it.
                FileHandle.standardError.write(Data("nawa: MCP server \(config.name) failed: \(AgentCLI.message(for: error))\n".utf8))
                await client.stop()
                continue
            }
            // Expose the MCP server's tools under prefixed names to avoid clashes.
            let prefix = PrefixedTool.prefix(forServer: config.name)
            for tool in await client.tools {
                mcpTools.append(PrefixedTool(prefix: prefix, wrapped: client, remote: tool))
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

    /// Providers reject a tool whose name isn't `[A-Za-z0-9_-]{1,64}`, and
    /// the server's name comes from the client, so it is cleaned and kept
    /// short enough to leave room for the tool's own name.
    public static func prefix(forServer serverName: String) -> String {
        String(allowedInToolNames(serverName).prefix(20)) + "__"
    }

    static let maxNameLength = 64

    static func allowedInToolNames(_ text: String) -> String {
        let cleaned = text.unicodeScalars.map { scalar -> Character in
            let isAllowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
            return isAllowed ? Character(scalar) : "_"
        }
        return String(cleaned)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: String((prefix + Self.allowedInToolNames(remote.name)).prefix(Self.maxNameLength)),
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
        // Writing to a pipe whose reader is gone (an MCP server that exited)
        // must fail that one write, not kill nawa and every session in it.
        signal(SIGPIPE, SIG_IGN)
        do {
            try await run()
        } catch let usage as UsageError {
            FileHandle.standardError.write(Data("nawa: \(usage.message)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("nawa: \(message(for: error))\n".utf8))
            exit(1)
        }
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    static let usage = """
        Usage: nawa [serve|acp|connect|repl|config|sessions|prompt|provider list]
          serve [--host <addr>] [--port <n>] [--token env:NAME|file:<path>]
                 — start the ACP server (streamable HTTP + WebSocket) on 127.0.0.1:7878. A non-loopback
                 --host needs a bearer token: without --token, one is created in ~/.local/state/nawa/serve-token
          acp    — speak ACP over stdio (for editors and Waku that launch the agent)
          connect <url> [--token env:NAME|file:<path>] — ACP over stdio, bridged to a remote nawa serve
                 (ws://, wss://, http://, https://; the token defaults to $NAWA_SERVE_TOKEN)
          repl [--plain] [--resume [id]] — chat with the agent in the terminal (--plain: line mode;
                 --resume: go on with a recorded session, by default this directory's newest; /help inside lists commands)
          sessions list|show|path|prune — the recorded sessions (nawa config set sessions off turns recording off)
          prompt [dir] — print the system prompt a session in this directory would get
          config [settings|set|unset] — configure providers (OpenAI-compatible or Anthropic) and settings for the current directory
          provider list [--json] — list the active provider's models
        """

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "serve"

        // Settings are resolved again for every session and `/clear`, so
        // what's wrong with the environment is said here, once.
        for problem in Settings.environmentProblems(ProcessInfo.processInfo.environment) {
            FileHandle.standardError.write(Data("nawa: \(problem)\n".utf8))
        }
        // Process-wide settings (session recording) come from the directory
        // nawa starts in; each session's own from its directory.
        let startSettings = Settings.resolved(for: WorkingDirectory.defaultURL)
        if let problem = Settings.problem(with: startSettings) {
            FileHandle.standardError.write(Data("nawa: \(problem)\n".utf8))
        }
        // Every session is recorded unless the `sessions` setting is off (proposal 0005).
        let sessions = sessionStore(startSettings)
        let gateways = GatewayCache()
        func sessionFactory(mode: String) -> HarnessSessionFactory {
            HarnessSessionFactory(
                gatewayForDirectory: { directory in try gateways.gateway(for: directory) },
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
            let environment = ProcessInfo.processInfo.environment
            let options = try RemoteAccess.serveOptions(
                arguments: Array(args.dropFirst()),
                environment: environment,
                stateDirectory: SessionStore.stateDirectory(environment: environment)
            )
            if let warning = RemoteAccess.warning(for: options) {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }
            let configuration = ACPServerConfiguration(
                hostname: options.host,
                port: options.port,
                capabilities: capabilities,
                idleSessionTimeout: sessions == nil ? nil : idleSessionTimeout(minutes: startSettings.sessionIdleMinutes),
                bearerToken: options.token
            )
            let server = ACPServer(configuration: configuration, factory: sessionFactory(mode: "serve"))
            // Said once bound, so the port is the real one (`--port 0` picks a free one).
            let app = server.buildApplication { channel in
                let port = channel.localAddress?.port ?? options.port
                var lines = "ACP server listening on http://\(RemoteAccess.authority(host: options.host, port: port))/acp\n"
                if let source = options.tokenSource {
                    lines += "Clients need the bearer token in \(source)\n"
                }
                // Unbuffered: a process supervisor or a pipe sees it at once.
                FileHandle.standardOutput.write(Data(lines.utf8))
            }
            try await app.runService()
        case "connect":
            let bridge = try RemoteAccess.connectBridge(arguments: Array(args.dropFirst()), environment: ProcessInfo.processInfo.environment)
            try await bridge.runOnStandardIO()
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
        case "help", "--help", "-h":
            print(usage)
        default:
            throw UsageError("unknown command \(command)\n" + usage)
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

    /// A recorded session to go on with: its journal, opened and locked
    /// first so no other nawa writes to it meanwhile, and the state it
    /// leaves. Nil when the journal never started a session.
    ///
    /// Lines that don't decode are reported on stderr. A context that
    /// names messages the journal lacks is refused: the model would get a
    /// conversation with holes in it.
    static func reopenSession(at url: URL, mode: String) throws -> (state: SessionState, journal: JournalFile)? {
        let sessionID = SessionStore.sessionID(inFileName: url.lastPathComponent) ?? url.lastPathComponent
        let journalFile: JournalFile
        do {
            journalFile = try JournalFile(continuing: url, origin: JournalOrigin(mode: mode, nawaVersion: ACPServerInfo.nawa.version)) { problem in
                FileHandle.standardError.write(Data("nawa: \(problem)\n".utf8))
            }
        } catch JournalFileError.inUse {
            throw CLIError.sessionInUse(sessionID)
        }
        let contents = JournalReader.read(url)
        reportUnreadableLines(contents, path: url.path)
        guard let state = contents.replay() else { return nil }
        let missing = contents.missingContextMessageIDs(ofSession: state.sessionID)
        if !missing.isEmpty {
            throw CLIError.damagedJournal(sessionID, missingMessages: missing.count)
        }
        return (state, journalFile)
    }

    /// Says on stderr (never stdout: in `acp` mode that is the protocol)
    /// how many lines of a journal were skipped.
    static func reportUnreadableLines(_ contents: JournalContents, path: String) {
        guard contents.skippedLines > 0 else { return }
        let lines = contents.skippedLines == 1 ? "1 journal line" : "\(contents.skippedLines) journal lines"
        FileHandle.standardError.write(Data("nawa: \(lines) could not be read in \(path)\n".utf8))
    }

    /// How long a `serve` session may sit without a prompt before it is
    /// unloaded: the `session_idle_minutes` setting, 30 by default.
    static func idleSessionTimeout(minutes: Double?) -> Duration {
        let defaultMinutes = 30.0
        // A value saved in the file by hand skips the setting's parsing,
        // and `Duration` traps on NaN or a huge number.
        guard let minutes, minutes.isFinite, minutes > 0 else { return .seconds(defaultMinutes * 60) }
        return .seconds(min(minutes, Settings.maxIdleMinutes) * 60)
    }

    /// Where sessions are recorded: nil when the `sessions` setting is off,
    /// else `sessions_dir`, else `SessionStore.defaultDirectory`.
    static func sessionStore(_ settings: DirectorySettings, environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionStore? {
        if settings.sessions == false { return nil }
        if let directory = settings.sessionsDirectory {
            return SessionStore(directory: URL(fileURLWithPath: directory))
        }
        return SessionStore(directory: SessionStore.defaultDirectory(environment: environment))
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
    /// `--resume`. Throws when another nawa has the session open.
    static func resumedSession(
        arguments: [String],
        sessions: SessionStore?,
        directory: URL = WorkingDirectory.defaultURL
    ) throws -> (state: SessionState, journal: JournalFile)? {
        guard let flag = arguments.firstIndex(of: "--resume") else { return nil }
        guard let sessions else { throw CLIError.resumeWithoutSessions }
        let next = arguments.index(after: flag)
        let hasValue = next < arguments.endIndex && !arguments[next].hasPrefix("--")
        let requestedID = hasValue ? arguments[next] : nil

        let found: URL?
        if let requestedID {
            found = sessions.journalURL(forSession: requestedID)
        } else {
            found = sessions.newestSession(inDirectory: directory.path, mode: "repl")
        }
        guard let url = found, let resumed = try reopenSession(at: url, mode: "repl") else {
            throw CLIError.noSessionToResume(requestedID)
        }
        return resumed
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

    /// Build the gateway for a session in `directory` (see `gatewayConfig`).
    static func resolveGateway(
        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Gateway {
        try gatewayConfig(directory: directory, environment: environment).makeGateway()
    }

    /// The providers a session in `directory` uses. Precedence:
    /// 1. `NAWA_GATEWAY_URL` / `NAWA_GATEWAY_API_KEY` / `NAWA_MODEL` env vars (explicit override);
    ///    `NAWA_GATEWAY_API=anthropic` switches it from the OpenAI wire API to Anthropic's.
    /// 2. The per-directory configuration saved by `nawa config` for `directory`.
    /// 3. `NAWA_GATEWAY_CONFIG` or a `Gateways.json` in `directory`.
    /// 4. The API's own endpoint (`NAWA_GATEWAY_API`, OpenAI by default) with
    ///    `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`.
    static func gatewayConfig(
        directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GatewayConfig {
        if let baseURL = environment["NAWA_GATEWAY_URL"] {
            return try environmentGatewayConfig(baseURL: baseURL, environment: environment)
        }

        let store = try AgentConfigStore.load(from: AgentConfigStore.defaultLocation(environment: environment))
        if let config = store.gatewayConfig(for: directory), !config.providers.isEmpty {
            return config.withEnvironmentDefaults(environment)
        }

        let fileConfig = try GatewayConfig.loadFromEnvironmentOrFile(directory: directory, environment: environment)
        if !fileConfig.providers.isEmpty {
            return fileConfig.withEnvironmentDefaults(environment)
        }

        return try environmentGatewayConfig(baseURL: nil, environment: environment)
    }

    /// One provider from the environment. Without a `baseURL` it is the
    /// API's own endpoint: an Anthropic key must never go to OpenAI's.
    static func environmentGatewayConfig(baseURL: String?, environment: [String: String]) throws -> GatewayConfig {
        var api = ProviderAPI.openAI
        if let requested = environment["NAWA_GATEWAY_API"] {
            guard let parsed = ProviderAPI(rawValue: requested.lowercased()) else {
                throw CLIError.unknownAPI(requested)
            }
            api = parsed
        }
        let isAnthropic = api == .anthropic
        let address = baseURL ?? (isAnthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1")
        guard let url = URL(string: address), url.scheme != nil, url.host != nil else {
            throw CLIError.invalidGatewayURL(address)
        }
        let fallbackKeyVariable = isAnthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        let provider = ProviderConfig(
            name: "default",
            api: api,
            baseURL: url,
            apiKey: environment["NAWA_GATEWAY_API_KEY"] ?? environment[fallbackKeyVariable],
            model: environment["NAWA_MODEL"]
        ).withEnvironmentDefaults(environment)
        return GatewayConfig(activeProvider: "default", providers: [provider])
    }

    /// The chat in the terminal. Settings come from `directory`'s saved
    /// settings plus the environment (`Settings.resolved`), read again
    /// for every new conversation; `/config` changes them while it runs.
    static func repl(
        gateway: Gateway,
        mode: ChatApp.Mode = .auto,
        directory: URL = WorkingDirectory.defaultURL,
        sessions: SessionStore? = nil,
        resume: (state: SessionState, journal: JournalFile)? = nil
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
                journal: resume.journal
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
                let lines: [String]
                do {
                    lines = try Settings.command(arguments, directory: directory, inSession: true)
                } catch {
                    return [message(for: error)]
                }
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

/// One gateway per directory for as long as the process runs, so ACP
/// sessions share failover cooldowns: a new session doesn't wait out a hung
/// primary provider that an earlier one already gave up on. Rebuilt when
/// the directory's configuration changes.
final class GatewayCache: Sendable {
    private struct Entry {
        var config: GatewayConfig
        var gateway: Gateway
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func gateway(for directory: URL) throws -> Gateway {
        let config = try AgentCLI.gatewayConfig(directory: directory, environment: environment)
        let key = AgentConfigStore.key(for: directory)
        return entries.withLock { entries in
            if let cached = entries[key], cached.config == config { return cached.gateway }
            let gateway = config.makeGateway()
            entries[key] = Entry(config: config, gateway: gateway)
            return gateway
        }
    }
}

/// Words on the command line nawa can't use: said on stderr, exit status 2.
struct UsageError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// `CustomStringConvertible` too: ACP replies put an error into words with
/// `"\(error)"`, which would otherwise print the case name.
enum CLIError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case unknownAPI(String)
    case invalidGatewayURL(String)
    case resumeWithoutSessions
    case noSessionToResume(String?)
    case sessionInUse(String)
    case damagedJournal(String, missingMessages: Int)

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
        case .sessionInUse(let id):
            return "session \(id) is open in another nawa"
        case .damagedJournal(let id, let missing):
            return "session \(id) can't be restored: its journal lacks \(missing) message(s) of its context"
        }
    }

    var description: String { errorDescription ?? "nawa error" }
}
