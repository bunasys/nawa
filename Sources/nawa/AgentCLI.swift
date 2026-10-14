import AgentACP
import AgentCore
import AgentGateway
import AgentInstructions
import AgentLoop
import AgentMCP
import AgentTools
import Foundation

// MARK: - A simple session factory that composes the whole harness

/// The default `ACPSessionFactory`: composes the gateway, built-in tools, any
/// MCP servers requested by the client, and the project's AGENTS.md
/// instructions into a ready-to-run `AgentLoop`.
///
/// The gateway is resolved per session from the session's working directory,
/// because `nawa config` stores providers per directory and one ACP process
/// may serve sessions in several projects.
public struct HarnessSessionFactory: ACPSessionFactory {
    public let gatewayForDirectory: @Sendable (URL) throws -> any LanguageModel
    public let baseTools: ToolRegistry
    public let loopOptions: LoopOptions

    public init(
        gatewayForDirectory: @escaping @Sendable (URL) throws -> any LanguageModel,
        baseTools: ToolRegistry,
        loopOptions: LoopOptions = .init()
    ) {
        self.gatewayForDirectory = gatewayForDirectory
        self.baseTools = baseTools
        self.loopOptions = loopOptions
    }

    public func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
        let gateway = try gatewayForDirectory(URL(fileURLWithPath: cwd))
        var tools = baseTools
        // Connect any MCP servers the client requested for this session.
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
                let prefixed = PrefixedTool(prefix: "\(config.name)__", wrapped: client, remote: tool)
                tools.register(prefixed)
            }
        }

        // Load AGENTS.md from the session's working directory.
        let instructions = try? ProjectInstructions.load(from: URL(fileURLWithPath: cwd))
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
            FileHandle.standardError.write(Data("agent: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "serve"

        // Built-in tools.
        let tools = ToolRegistry([CurrentTimeTool(), EchoTool(), ShellTool()])
        let sessionFactory = HarnessSessionFactory(
            gatewayForDirectory: { directory in try resolveGateway(directory: directory) },
            baseTools: tools
        )

        // Waku launches the agent as a Kimi Code CLI and generates commit
        // messages with `--prompt …` (see WakuCompatibility.swift).
        if args.contains("--prompt") {
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
            try await repl(gateway: gateway, tools: tools)
        case "config":
            try await ConfigCommand.run(arguments: Array(args.dropFirst()))
        default:
            print("Usage: nawa [serve|acp|repl|config|provider list]")
            print("  serve  — start the ACP server (streamable HTTP + WebSocket) on :7878")
            print("  acp    — speak ACP over stdio (for editors and Waku that launch the agent)")
            print("  repl   — run a single prompt from stdin against the agent loop")
            print("  config — configure a provider (OpenAI-compatible or Anthropic) for the current directory")
            print("  provider list [--json] — list the active provider's models")
        }
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
            return config.makeGateway()
        }

        let fileConfig = try GatewayConfig.loadFromEnvironmentOrFile()
        if !fileConfig.providers.isEmpty {
            return fileConfig.makeGateway()
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
        let fallbackKeyVariable = api == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        let provider = ProviderConfig(
            name: "default",
            api: api,
            baseURL: URL(string: baseURL)!,
            apiKey: env["NAWA_GATEWAY_API_KEY"] ?? env[fallbackKeyVariable],
            model: env["NAWA_MODEL"]
        )
        return Gateway(providers: [provider], activeProviderName: "default")
    }

    static func repl(gateway: any LanguageModel, tools: ToolRegistry) async throws {
        let instructions = try? ProjectInstructions.loadForCurrentWorkingDirectory()
        let loop = AgentLoop(
            gateway: gateway,
            tools: tools,
            systemPrompt: instructions?.text,
            options: LoopOptions(maxTurns: 20)
        )
        print("Nawa REPL (type a prompt, Ctrl-D to quit)")
        while let line = readLine() {
            let stream = loop.run(prompt: line, continuing: true)
            for try await event in stream {
                switch event {
                case .assistant(let update):
                    if !update.text.isEmpty { print("🤖 \(update.text)") }
                    for call in update.toolCalls {
                        print("🔧 \(call.name)(\(call.arguments.description))")
                    }
                case .toolResult(let result):
                    print("← \(result.name): \(result.content.prefix(200))")
                case .result(let result):
                    if !result.isSuccess {
                        print("⚠️ \(result.errorMessage ?? result.kind.rawValue)")
                    }
                default:
                    break
                }
            }
            print()
        }
    }
}

enum CLIError: Error, LocalizedError {
    case unknownAPI(String)

    var errorDescription: String? {
        switch self {
        case .unknownAPI(let value):
            let known = ProviderAPI.allCases.map(\.rawValue).joined(separator: ", ")
            return "NAWA_GATEWAY_API=\(value) is not one of: \(known)"
        }
    }
}
