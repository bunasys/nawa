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
/// MCP servers requested by the client, and the project's AGENTS.md
/// instructions into a ready-to-run `AgentLoop`, recorded in a journal in
/// `sessions` so `session/load` can bring it back.
///
/// The gateway and the built-in tools are made per session from the
/// session's working directory, because `nawa config` stores providers per
/// directory and one ACP process may serve sessions in several projects.
public struct HarnessSessionFactory: ACPSessionFactory {
    public let gatewayForDirectory: @Sendable (URL) throws -> any LanguageModel
    public let loopOptions: LoopOptions
    /// Where journals go; nil records nothing and can't restore.
    public let sessions: SessionStore?
    /// `acp` or `serve`, for the journal.
    public let mode: String

    /// Past this many MCP tools, they are offered through `tool_search` and
    /// `call_tool` instead of one definition each (see DeferredTools.swift).
    static let maxDirectMCPTools = 10

    public init(
        gatewayForDirectory: @escaping @Sendable (URL) throws -> any LanguageModel,
        loopOptions: LoopOptions = .init(),
        sessions: SessionStore? = nil,
        mode: String = "acp"
    ) {
        self.gatewayForDirectory = gatewayForDirectory
        self.loopOptions = loopOptions
        self.sessions = sessions
        self.mode = mode
    }

    public func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        let (gateway, tools, systemPrompt) = try await parts(cwd: cwd, mcpServers: mcpServers)
        let journal = sessions.map { AgentCLI.journal(at: $0.newJournalURL(sessionID: sessionID), mode: mode) }
        return AgentLoop(
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: loopOptions,
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
        let (gateway, tools, systemPrompt) = try await parts(cwd: state.cwd, mcpServers: mcpServers)
        return AgentLoop(
            restoring: state,
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: loopOptions,
            journal: AgentCLI.journal(at: url, mode: mode)
        )
    }

    /// What a session in `cwd` runs with: its directory's gateway, the
    /// built-in and MCP tools, and its AGENTS.md.
    private func parts(cwd: String, mcpServers: [MCPServerConfig]) async throws -> (any LanguageModel, ToolRegistry, String?) {
        let directory = URL(fileURLWithPath: cwd)
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

        // Load AGENTS.md from the session's working directory.
        let instructions = try? ProjectInstructions.load(from: directory)
        return (gateway, tools, instructions?.text)
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

        let loopOptions = defaultLoopOptions()
        // Every session is recorded unless NAWA_SESSIONS=off (proposal 0005).
        let sessions = SessionStore.fromEnvironment()
        func sessionFactory(mode: String) -> HarnessSessionFactory {
            HarnessSessionFactory(
                gatewayForDirectory: { directory in try resolveGateway(directory: directory) },
                loopOptions: loopOptions,
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
                idleSessionTimeout: sessions == nil ? nil : idleSessionTimeout()
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
            let gateway = try resolveGateway()
            let plain = replArgs.contains("--plain")
            let resume = try resumedSession(arguments: replArgs, sessions: sessions)
            try await repl(gateway: gateway, options: loopOptions, mode: plain ? .plain : .auto, sessions: sessions, resume: resume)
        case "config":
            try await ConfigCommand.run(arguments: Array(args.dropFirst()))
        case "sessions":
            try SessionsCommand.run(arguments: Array(args.dropFirst()), sessions: sessions)
        default:
            print("Usage: nawa [serve|acp|repl|config|provider list]")
            print("  serve  — start the ACP server (streamable HTTP + WebSocket) on :7878")
            print("  acp    — speak ACP over stdio (for editors and Waku that launch the agent)")
            print("  repl [--plain] [--resume [id]] — chat with the agent in the terminal (--plain: line mode;")
            print("         --resume: go on with a recorded session, by default this directory's newest; /help inside lists commands)")
            print("  sessions list|show|path|prune — the recorded sessions (NAWA_SESSIONS=off turns recording off)")
            print("  config — configure a provider (OpenAI-compatible or Anthropic) for the current directory")
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
    static func idleSessionTimeout(env: [String: String] = ProcessInfo.processInfo.environment) -> Duration {
        let defaultMinutes = 30.0
        guard let text = env["NAWA_SESSION_IDLE_MINUTES"] else { return .seconds(defaultMinutes * 60) }
        guard let minutes = Double(text), minutes > 0 else {
            FileHandle.standardError.write(Data("nawa: ignoring NAWA_SESSION_IDLE_MINUTES=\(text); expected a positive number\n".utf8))
            return .seconds(defaultMinutes * 60)
        }
        return .seconds(minutes * 60)
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

    /// Token-saving defaults for interactive sessions. `NAWA_HELPER_MODEL`
    /// names a cheaper model for sub-agents and summaries; it must be served
    /// by the same provider as the main model. `NAWA_PRICE` and
    /// `NAWA_HELPER_PRICE` (`"input,output"` USD per million tokens) turn on
    /// cost estimates. `NAWA_MAX_BUDGET_USD` stops a prompt once the session's
    /// estimated cost reaches it, so it needs `NAWA_PRICE`. Replies stream
    /// (progress while the model thinks) unless `NAWA_STREAM=0`.
    /// `NAWA_FALLBACK_MODEL` names the model to retry on when the session's
    /// model declines a prompt (same provider).
    static func defaultLoopOptions(env: [String: String] = ProcessInfo.processInfo.environment) -> LoopOptions {
        LoopOptions(
            maxBudgetUSD: maxBudget(env),
            pricing: pricing(env, "NAWA_PRICE"),
            keepToolResults: 20,
            compaction: Compaction(atContextTokens: 120_000, keepRecentMessages: 20),
            subAgents: true,
            helperModel: env["NAWA_HELPER_MODEL"],
            helperPricing: pricing(env, "NAWA_HELPER_PRICE"),
            streamReplies: env["NAWA_STREAM"] != "0",
            fallbackModel: env["NAWA_FALLBACK_MODEL"]
        )
    }

    private static func maxBudget(_ env: [String: String]) -> Double? {
        guard let text = env["NAWA_MAX_BUDGET_USD"] else { return nil }
        guard let budget = Double(text), budget > 0 else {
            FileHandle.standardError.write(Data("nawa: ignoring NAWA_MAX_BUDGET_USD=\(text); expected a positive number of USD\n".utf8))
            return nil
        }
        if env["NAWA_PRICE"] == nil {
            FileHandle.standardError.write(Data("nawa: NAWA_MAX_BUDGET_USD has no effect without NAWA_PRICE\n".utf8))
        }
        return budget
    }

    private static func pricing(_ env: [String: String], _ name: String) -> Pricing? {
        guard let text = env[name] else { return nil }
        guard let pricing = Pricing(perMillionTokens: text) else {
            FileHandle.standardError.write(Data("nawa: ignoring \(name)=\(text); expected \"input,output\" USD per million tokens\n".utf8))
            return nil
        }
        return pricing
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

    static func repl(
        gateway: Gateway,
        options: LoopOptions,
        mode: ChatApp.Mode = .auto,
        sessions: SessionStore? = nil,
        resume: (state: SessionState, url: URL)? = nil
    ) async throws {
        let instructions = try? ProjectInstructions.loadForCurrentWorkingDirectory()
        let directory = WorkingDirectory.defaultURL
        let tools = ToolRegistry(builtInTools(workingDirectory: directory))
        // No turn cap, like Claude Code: the loop check (LoopOptions.loopCheckAfterTurns)
        // stops a stuck run, and NAWA_MAX_BUDGET_USD caps the spend.
        @Sendable func makeLoop() -> AgentLoop {
            let sessionID = UUID().uuidString
            return AgentLoop(
                gateway: gateway,
                tools: tools,
                systemPrompt: instructions?.text,
                options: options,
                sessionID: sessionID,
                journal: sessions.map { journal(at: $0.newJournalURL(sessionID: sessionID), mode: "repl") }
            )
        }
        let firstLoop: AgentLoop
        if let resume {
            firstLoop = AgentLoop(
                restoring: resume.state,
                gateway: gateway,
                tools: tools,
                systemPrompt: instructions?.text,
                options: options,
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
                hasInstructions: instructions != nil
            ),
            contextLimit: options.compaction?.atContextTokens,
            tools: loop.withLock { $0.toolDefinitions.map(\.name) },
            history: resume?.state.messages ?? [],
            send: { prompt in loop.withLock { $0 }.run(prompt: prompt, continuing: true) },
            reset: { loop.withLock { $0 = makeLoop() } },
            removeDeclinedRequest: { loop.withLock { $0 }.removeDeclinedRequest() }
        )
        try await ChatApp.run(session, mode: mode, maxTurns: options.maxTurns)
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
            return "--resume needs recorded sessions, but NAWA_SESSIONS is off"
        case .noSessionToResume(let id?):
            return "no recorded session \(id) (nawa sessions list --all shows them)"
        case .noSessionToResume(nil):
            return "no recorded session in this directory (nawa sessions list shows them)"
        }
    }
}
