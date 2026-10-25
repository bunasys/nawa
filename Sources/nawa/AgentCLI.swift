import Synchronization
import AgentACP
import AgentCore
import AgentGateway
import AgentInstructions
import AgentLoop
import AgentMCP
import AgentTools
import AgentTUI
import Foundation

// MARK: - A simple session factory that composes the whole harness

/// The default `ACPSessionFactory`: composes the gateway, built-in tools, any
/// MCP servers requested by the client, and the project's AGENTS.md
/// instructions into a ready-to-run `AgentLoop`.
///
/// The gateway and the built-in tools are made per session from the
/// session's working directory, because `nawa config` stores providers per
/// directory and one ACP process may serve sessions in several projects.
public struct HarnessSessionFactory: ACPSessionFactory {
    public let gatewayForDirectory: @Sendable (URL) throws -> any LanguageModel
    public let loopOptions: LoopOptions

    /// Past this many MCP tools, they are offered through `tool_search` and
    /// `call_tool` instead of one definition each (see DeferredTools.swift).
    static let maxDirectMCPTools = 10

    public init(
        gatewayForDirectory: @escaping @Sendable (URL) throws -> any LanguageModel,
        loopOptions: LoopOptions = .init()
    ) {
        self.gatewayForDirectory = gatewayForDirectory
        self.loopOptions = loopOptions
    }

    public func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
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
        let systemPrompt = instructions?.text

        return AgentLoop(
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: loopOptions,
            cwd: cwd
        )
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
        let sessionFactory = HarnessSessionFactory(
            gatewayForDirectory: { directory in try resolveGateway(directory: directory) },
            loopOptions: loopOptions
        )

        // Waku launches the agent as a Kimi Code CLI and generates commit
        // messages with `--prompt …` (see WakuCompatibility.swift). Only
        // flags, no subcommand: `nawa config --prompt` is not a one-shot.
        if command.hasPrefix("--"), args.contains("--prompt") {
            try await WakuCompatibility.oneShotPrompt(arguments: args)
            return
        }

        switch command {
        case "--version", "version":
            print("nawa \(ACPServerInfo.nawa.version)")
        case "serve":
            let server = ACPServer(factory: sessionFactory)
            let app = server.buildApplication()
            print("ACP server listening on http://127.0.0.1:7878/acp")
            try await app.runService()
        case "acp":
            try await ACPStdioTransport(factory: sessionFactory).run()
        case "provider":
            try await WakuCompatibility.providerCommand(arguments: Array(args.dropFirst()))
        case "repl":
            let gateway = try resolveGateway()
            let plain = args.dropFirst().contains("--plain")
            try await repl(gateway: gateway, options: loopOptions, mode: plain ? .plain : .auto)
        case "config":
            try await ConfigCommand.run(arguments: Array(args.dropFirst()))
        default:
            print("Usage: nawa [serve|acp|repl|config|provider list]")
            print("  serve  — start the ACP server (streamable HTTP + WebSocket) on :7878")
            print("  acp    — speak ACP over stdio (for editors and Waku that launch the agent)")
            print("  repl [--plain] — chat with the agent in the terminal (--plain: line mode; /help inside lists commands)")
            print("  config — configure a provider (OpenAI-compatible or Anthropic) for the current directory")
            print("  provider list [--json] — list the active provider's models")
        }
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

    static func repl(gateway: Gateway, options: LoopOptions, mode: ChatApp.Mode = .auto) async throws {
        let instructions = try? ProjectInstructions.loadForCurrentWorkingDirectory()
        let directory = WorkingDirectory.defaultURL
        // No turn cap, like Claude Code: the loop check (LoopOptions.loopCheckAfterTurns)
        // stops a stuck run, and NAWA_MAX_BUDGET_USD caps the spend.
        @Sendable func makeLoop() -> AgentLoop {
            AgentLoop(
                gateway: gateway,
                tools: ToolRegistry(builtInTools(workingDirectory: directory)),
                systemPrompt: instructions?.text,
                options: options
            )
        }
        // `/clear` swaps in a fresh loop: a new conversation, same tools.
        let loop = Mutex(makeLoop())
        let session = ChatSession(
            header: SessionHeader(
                provider: gateway.activeProvider?.name,
                model: gateway.activeProvider?.model,
                directory: displayPath(directory),
                hasInstructions: instructions != nil
            ),
            contextLimit: options.compaction?.atContextTokens,
            tools: loop.withLock { $0.toolDefinitions.map(\.name) },
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

    var errorDescription: String? {
        switch self {
        case .unknownAPI(let value):
            let known = ProviderAPI.allCases.map(\.rawValue).joined(separator: ", ")
            return "NAWA_GATEWAY_API=\(value) is not one of: \(known)"
        case .invalidGatewayURL(let value):
            return "NAWA_GATEWAY_URL=\(value) is not an absolute URL"
        }
    }
}
