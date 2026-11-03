import AgentCore
import AgentJSONRPC
import Foundation

/// Configuration for launching an MCP server as a subprocess (stdio transport).
public struct MCPServerConfig: Sendable, Hashable, Codable {
    public var name: String
    /// A path, or a bare name (`npx`) looked up on the server's `PATH`.
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// Where the server runs; nil inherits this process's directory.
    public var workingDirectory: String?
    /// Seconds to wait for `initialize` and `tools/list`; nil means
    /// `MCPClient.defaultRequestTimeout`.
    public var requestTimeout: Double?
    /// Seconds to wait for a `tools/call`; nil means
    /// `MCPClient.defaultToolCallTimeout`.
    public var toolCallTimeout: Double?

    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        requestTimeout: Double? = nil,
        toolCallTimeout: Double? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
        self.requestTimeout = requestTimeout
        self.toolCallTimeout = toolCallTimeout
    }
}

/// Why a call to an MCP server failed.
public enum MCPClientError: Error, Sendable, CustomStringConvertible {
    /// The server answered with a JSON-RPC error.
    case serverError(code: Int, message: String)
    /// The server closed its output (it exited or crashed).
    case serverExited(server: String)
    /// No answer arrived in time.
    case timedOut(method: String, seconds: Double)
    /// `command` has no slash and no directory on `PATH` holds it.
    case commandNotFound(String)

    /// The text a failed tool call shows the model.
    public var description: String {
        switch self {
        case .serverError(let code, let message): return "MCP server error \(code): \(message)"
        case .serverExited(let server): return "MCP server '\(server)' exited"
        case .timedOut(let method, let seconds): return "MCP server did not answer \(method) within \(seconds) s"
        case .commandNotFound(let command): return "MCP server command not found on PATH: \(command)"
        }
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
/// values and runs them via `tools/call`. A call never waits forever: it
/// fails when the server answers with an error, exits, takes longer than
/// its timeout, or the calling task is cancelled.
public actor MCPClient {
    /// How long `initialize` and `tools/list` may take.
    public static let defaultRequestTimeout: Double = 60
    /// How long a tool call may take: tools do real work (builds,
    /// searches), so they get the ten minutes a model call gets.
    public static let defaultToolCallTimeout: Double = 600

    public let name: String
    public private(set) var tools: [MCPToolDefinition] = []

    private let config: MCPServerConfig
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var nextID: Int = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSON, Error>] = [:]
    private var readBuffer = Data()
    private var readTask: Task<Void, Never>?
    private var exitError: MCPClientError?
    private var started = false

    public init(config: MCPServerConfig) {
        self.name = config.name
        self.config = config
    }

    /// Start the subprocess and perform protocol initialization.
    public func start() async throws {
        guard !started else { return }
        started = true
        let environment = ProcessInfo.processInfo.environment.merging(config.env) { _, new in new }
        process.executableURL = try Self.executableURL(
            for: config.command,
            searchPath: environment["PATH"],
            workingDirectory: config.workingDirectory
        )
        process.arguments = config.args
        process.environment = environment
        if let workingDirectory = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        startReading()

        let setupTimeout = config.requestTimeout ?? Self.defaultRequestTimeout
        _ = try await request(method: "initialize", params: .object([
            "protocolVersion": .string(MCPProtocolVersion.supported),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("nawa"),
                // The release version lives in AgentACP, which this module
                // does not depend on.
                "version": .string("dev"),
            ]),
        ]), timeout: setupTimeout)
        try send(.makeNotification(method: "notifications/initialized", params: .object([:])))

        let toolsResult = try await request(method: "tools/list", params: .object([:]), timeout: setupTimeout)
        if let tools = toolsResult.objectValue?["tools"]?.arrayValue {
            self.tools = tools.compactMap { try? $0.decode(MCPToolDefinition.self) }
        }
    }

    /// Invoke a tool on the server and render its content as a string.
    public func callTool(name: String, arguments: JSON) async throws -> String {
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]), timeout: config.toolCallTimeout ?? Self.defaultToolCallTimeout)
        let content = result.objectValue?["content"]?.arrayValue ?? []
        var text = content.compactMap { block -> String? in
            guard case .object(let obj) = block else { return nil }
            if let t = obj["text"]?.stringValue { return t }
            if let uri = obj["uri"]?.stringValue { return "resource: \(uri)" }
            return nil
        }.joined(separator: "\n")
        if let isError = result.objectValue?["isError"]?.boolValue, isError {
            text = "ERROR:\n" + text
        }
        return text.isEmpty ? "(no content)" : text
    }

    /// A client nobody holds any more (its session was closed or unloaded)
    /// takes its server down with it.
    deinit {
        stdout.fileHandleForReading.readabilityHandler = nil
        readTask?.cancel()
        if process.isRunning {
            try? stdin.fileHandleForWriting.close()
            process.terminate()
        }
    }

    public func stop() {
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }

    // MARK: - Launching

    /// Where `command` lives. A bare name is looked up on `searchPath` as a
    /// shell would; `Process` alone would look for it in the current
    /// directory. A path with a slash is used as is, relative to the
    /// server's working directory.
    static func executableURL(for command: String, searchPath: String?, workingDirectory: String?) throws -> URL {
        let baseDirectory = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if command.contains("/") {
            return URL(fileURLWithPath: command, relativeTo: baseDirectory).absoluteURL
        }
        let directories = (searchPath ?? "").split(separator: ":").map(String.init)
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw MCPClientError.commandNotFound(command)
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: JSON?, timeout seconds: Double) async throws -> JSON {
        if let exitError { throw exitError }
        try Task.checkCancellation()
        let id = JSONRPCID.number(nextID)
        nextID += 1

        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(seconds))
            await self?.fail(id, with: MCPClientError.timedOut(method: method, seconds: seconds))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.makeRequest(method: method, id: id, params: params))
                } catch {
                    fail(id, with: error)
                }
            }
        } onCancel: {
            // Runs off the actor. The hop waits behind the code that
            // registers the continuation, so it always finds the entry.
            Task { await self.fail(id, with: CancellationError()) }
        }
    }

    private func fail(_ id: JSONRPCID, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func send(_ message: JSONRPCMessage) throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data(message.line.utf8))
    }

    /// Reads the server's output in order: the readability handler only
    /// queues chunks and one task consumes them, so a line split across
    /// chunks is always put back together.
    private func startReading() {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else {
                chunkSink.yield(data)
                return
            }
            handle.readabilityHandler = nil
            chunkSink.finish()
        }
        readTask = Task { [weak self] in
            for await chunk in chunks {
                await self?.onRead(chunk)
            }
            await self?.serverClosedOutput()
        }
    }

    private func onRead(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: readBuffer[readBuffer.startIndex..<newline], as: UTF8.self)
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard let message = try? parseJSONRPCLine(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        switch message {
        case .successResponse(let response):
            pending.removeValue(forKey: response.id)?.resume(returning: response.result ?? .null)
        case .errorResponse(let response):
            guard let id = response.id else { return }
            fail(id, with: MCPClientError.serverError(code: response.error.code, message: response.error.message))
        case .request(let request):
            answer(request)
        case .notification:
            break
        }
    }

    /// The server may ask us things too, `ping` at any time. Its ids are
    /// its own numbering, so its requests are never matched to our calls.
    private func answer(_ request: JSONRPCRequest) {
        let reply: JSONRPCMessage = request.method == "ping"
            ? .makeSuccess(id: request.id, result: .object([:]))
            : .makeError(id: request.id, code: .methodNotFound, message: "method not found: \(request.method)")
        try? send(reply)
    }

    private func serverClosedOutput() {
        let error = MCPClientError.serverExited(server: name)
        exitError = error
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
