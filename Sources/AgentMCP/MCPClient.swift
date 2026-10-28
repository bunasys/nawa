import AgentCore
import AgentJSONRPC
import Foundation

/// Configuration for launching an MCP server as a subprocess (stdio transport).
public struct MCPServerConfig: Sendable, Hashable, Codable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]

    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

/// A single tool announced by an MCP server via `tools/list`.
public struct MCPToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String?
    public var inputSchema: JSON?

    public init(name: String, description: String? = nil, inputSchema: JSON? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// As a harness `ToolDefinition` (gateway-facing).
    public var asToolDefinition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description ?? "(no description)",
            parameters: inputSchema ?? .object(["type": .string("object")])
        )
    }
}

/// The MCP protocol version we speak.
public enum MCPProtocolVersion {
    /// Latest widely-deployed MCP protocol version.
    public static let supported = "2025-06-18"
}

/// One connection to an MCP server over stdio (a spawned subprocess).
///
/// The client speaks JSON-RPC 2.0 over the subprocess's stdin/stdout,
/// newline-delimited. It exposes the server's tools as `MCPToolDefinition`
/// values and runs them via `tools/call`.
public actor MCPClient {
    public let name: String
    public private(set) var tools: [MCPToolDefinition] = []

    private let command: String
    private let args: [String]
    private let env: [String: String]
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<JSON?, Error>] = [:]
    private var readBuffer = Data()
    private var started = false

    public init(config: MCPServerConfig) {
        self.name = config.name
        self.command = config.command
        self.args = config.args
        self.env = config.env
    }

    /// Start the subprocess and perform protocol initialization.
    public func start() async throws {
        guard !started else { return }
        started = true
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        // Begin reading responses in the background.
        startReadLoop()

        let initResult = try await request(method: "initialize", params: .object([
            "protocolVersion": .string(MCPProtocolVersion.supported),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("swift-agent"),
                "version": .string("0.1.0"),
            ]),
        ]))
        _ = initResult
        send(.makeNotification(method: "notifications/initialized", params: .object([:])))

        let toolsResult = try await request(method: "tools/list", params: .object([:]))
        if let tools = toolsResult?.objectValue?["tools"]?.arrayValue {
            self.tools = tools.compactMap { try? $0.decode(MCPToolDefinition.self) }
        }
    }

    /// Invoke a tool on the server and render its content as a string.
    public func callTool(name: String, arguments: JSON) async throws -> String {
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        let content = result?.objectValue?["content"]?.arrayValue ?? []
        var text = content.compactMap { block -> String? in
            guard case .object(let obj) = block else { return nil }
            if let t = obj["text"]?.stringValue { return t }
            if let uri = obj["uri"]?.stringValue { return "resource: \(uri)" }
            return nil
        }.joined(separator: "\n")
        if let isError = result?.objectValue?["isError"]?.boolValue, isError {
            text = "ERROR:\n" + text
        }
        return text.isEmpty ? "(no content)" : text
    }

    /// A client nobody holds any more (its session was closed or unloaded)
    /// takes its server down with it.
    deinit {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            try? stdin.fileHandleForWriting.close()
            process.terminate()
        }
    }

    public func stop() {
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: JSON?) async throws -> JSON? {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(.makeRequest(method: method, id: .number(id), params: params))
        }
    }

    private func send(_ message: JSONRPCMessage) {
        let line = message.json.description + "\n"
        if let data = line.data(using: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func startReadLoop() {
        let handle = stdout.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.onRead(data)
            }
        }
    }

    private func onRead(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[readBuffer.startIndex..<newline])
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard let json = try? JSONDecoder().decode(JSON.self, from: line) else { continue }
            if let id = json.objectValue?["id"]?.intValue {
                let result = json.objectValue?["result"]
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
