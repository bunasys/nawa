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
public struct HarnessSessionFactory: ACPSessionFactory {
    public let gateway: any LanguageModel
    public let baseTools: ToolRegistry
    public let loopOptions: LoopOptions

    public init(gateway: any LanguageModel, baseTools: ToolRegistry, loopOptions: LoopOptions = .init()) {
        self.gateway = gateway
        self.baseTools = baseTools
        self.loopOptions = loopOptions
    }

    public func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop {
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
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        let command = args.first ?? "serve"

        // Build a gateway from environment variables (OpenAI-compatible).
        let baseURL = ProcessInfo.processInfo.environment["AGENT_GATEWAY_URL"]
            ?? "https://api.openai.com/v1"
        let apiKey = ProcessInfo.processInfo.environment["AGENT_GATEWAY_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let model = ProcessInfo.processInfo.environment["AGENT_MODEL"]

        let provider = ProviderConfig(
            name: "default",
            baseURL: URL(string: baseURL)!,
            apiKey: apiKey,
            model: model
        )
        let gateway = Gateway(providers: [provider], activeProviderName: "default")

        // Built-in tools.
        let tools = ToolRegistry([CurrentTimeTool(), EchoTool(), ShellTool()])

        switch command {
        case "serve":
            let sessionFactory = HarnessSessionFactory(gateway: gateway, baseTools: tools)
            let server = ACPServer(factory: sessionFactory)
            let app = server.buildApplication()
            print("ACP server listening on http://127.0.0.1:7878/acp")
            try await app.runService()
        case "repl":
            try await repl(gateway: gateway, tools: tools)
        default:
            print("Usage: agent [serve|repl]")
            print("  serve — start the ACP server (streamable HTTP + WebSocket) on :7878")
            print("  repl  — run a single prompt from stdin against the agent loop")
        }
    }

    static func repl(gateway: any LanguageModel, tools: ToolRegistry) async throws {
        let instructions = try? ProjectInstructions.loadForCurrentWorkingDirectory()
        let loop = AgentLoop(
            gateway: gateway,
            tools: tools,
            systemPrompt: instructions?.text,
            options: LoopOptions(maxTurns: 20)
        )
        print("Agent REPL (type a prompt, Ctrl-D to quit)")
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
                        print("⚠️ \(result.kind.rawValue)")
                    }
                default:
                    break
                }
            }
            print()
        }
    }
}
