import AgentCore
import AgentGateway
import AgentJSONRPC
import AgentLoop
import AgentMCP
import AgentTools
import Foundation

/// Builds the agent loop for a new ACP session.
///
/// The factory is the seam where the ACP server composes the gateway, the
/// built-in tools, any MCP servers requested by the client, and the project
/// instructions (AGENTS.md) into a ready-to-run `AgentLoop`.
public protocol ACPSessionFactory: Sendable {
    /// - Parameters:
    ///   - sessionID: The ACP session id.
    ///   - cwd: Working directory for the session.
    ///   - mcpServers: MCP server configs the client asked the agent to connect.
    /// - Returns: A configured agent loop.
    func makeLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop

    /// Rebuilds a session from its journal (proposal 0005), for
    /// `session/load` and for a session unloaded while idle.
    /// - Returns: The restored loop, or nil when the session is unknown.
    func restoreLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop?
}

extension ACPSessionFactory {
    /// Factories without journals can't restore sessions.
    public func restoreLoop(sessionID: String, cwd: String, mcpServers: [MCPServerConfig]) async throws -> AgentLoop? {
        nil
    }
}

/// How a connection delivers its outbound messages.
///
/// The transport decides, because it is the transport that knows how many
/// pipes it has.
public enum ACPOutboundRouting: Sendable {
    /// Streamable HTTP: session-scoped messages go to that session's SSE
    /// stream, everything else to the connection stream.
    case perSession
    /// stdio and WebSocket: one pipe, so every message goes to the
    /// connection stream regardless of its route.
    case singleStream
}

/// One ACP connection (one `Acp-Connection-Id`).
///
/// Owns the connection-scoped outbound stream and the per-session streams, and
/// dispatches inbound JSON-RPC messages to the right session (or to the
/// connection itself for `session/new` / `session/load`).
public actor ACPConnection {
    public let connectionID: String
    private let factory: any ACPSessionFactory
    private let info: ACPServerInfo
    private let capabilities: ACPCapabilities
    private let routing: ACPOutboundRouting

    private let connectionStream = ACPEventStream()
    private var sessionStreams: [String: ACPEventStream] = [:]
    /// Sessions in memory. An idle one may be dropped from here and rebuilt
    /// from its journal on its next request (see `unloadIdleSessions`).
    private var sessions: [String: ACPSession] = [:]
    /// How every session of this connection was set up, loaded or not.
    private var setups: [String: SessionSetup] = [:]
    private var idleSweeper: Task<Void, Never>?

    private struct SessionSetup {
        var cwd: String
        var mcpServers: [MCPServerConfig]
    }

    public init(
        connectionID: String,
        factory: any ACPSessionFactory,
        info: ACPServerInfo = .nawa,
        capabilities: ACPCapabilities = .init(),
        routing: ACPOutboundRouting = .perSession
    ) {
        self.connectionID = connectionID
        self.factory = factory
        self.info = info
        self.capabilities = capabilities
        self.routing = routing
    }

    deinit {
        idleSweeper?.cancel()
    }

    /// The connection-scoped outbound stream (for SSE GET handlers).
    public var outbound: AsyncStream<JSONRPCMessage> { connectionStream.stream }

    /// Ends the connection-scoped stream once what is already queued on it
    /// has been read; later messages are dropped. For a transport whose
    /// client has gone (stdin closed) but whose last replies must still go out.
    public func finishOutbound() {
        connectionStream.finish()
    }

    /// The session-scoped outbound stream for `sessionID`, creating it if needed.
    public func sessionOutbound(for sessionID: String) -> AsyncStream<JSONRPCMessage> {
        if sessionStreams[sessionID] == nil {
            sessionStreams[sessionID] = ACPEventStream()
        }
        return sessionStreams[sessionID]!.stream
    }

    /// Handle one raw inbound frame (a stdio line or a WebSocket text
    /// message). A frame that is not a JSON-RPC message gets the spec's
    /// parse-error reply, so the client is not left waiting.
    public func handle(text: String) async {
        let message: JSONRPCMessage
        do {
            message = try parseJSONRPCLine(text)
        } catch {
            connectionStream.publish(.parseFailure(error))
            return
        }
        await handle(message)
    }

    /// Handle an inbound JSON-RPC message.
    public func handle(_ message: JSONRPCMessage) async {
        switch message {
        case .request(let request):
            await handleRequest(request)
        case .notification(let notification):
            await handleNotification(notification)
        default:
            break
        }
    }

    /// The `initialize` result.
    public func initializeResult() -> JSON {
        .object([
            "protocolVersion": .int(ACPProtocolVersion.v1.rawValue),
            "agentCapabilities": capabilities.json,
            "agentInfo": info.json,
            "authMethods": .array([]),
        ])
    }

    // MARK: - Dispatch

    private func handleRequest(_ request: JSONRPCRequest) async {
        switch request.method {
        case "initialize":
            // stdio and WebSocket route `initialize` here like any other
            // request. Streamable HTTP must answer it in the POST response,
            // because that response creates the connection (see ACPServer).
            connectionStream.publish(.makeSuccess(id: request.id, result: initializeResult()))
        case "session/new":
            await newSession(request: request)
        case "session/load":
            await loadSession(request: request)
        case "session/prompt":
            await prompt(request: request)
        case "session/set_model":
            await setModel(request: request)
        case "session/request_permission":
            // A client→agent *response* to our permission request arrives here
            // as a result; but a request with this method is unexpected. Ignore.
            break
        default:
            connectionStream.publish(
                .makeError(id: request.id, code: .methodNotFound, message: "unknown method \(request.method)")
            )
        }
    }

    private func handleNotification(_ notification: JSONRPCMethod) async {
        switch notification.method {
        case "session/cancel":
            // An unloaded session has no prompt running, so it isn't rebuilt.
            if let sessionID = notification.params?.objectValue?["sessionId"]?.stringValue {
                await sessions[sessionID]?.cancel()
            }
        default:
            break
        }
    }

    // MARK: - Methods

    private func newSession(request: JSONRPCRequest) async {
        let params = request.params ?? .object([:])
        let cwd = params.objectValue?["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
        let sessionID = "sess_\(UUID().uuidString.prefix(12))"
        let mcpServers = decodeMCPServers(params.objectValue?["mcpServers"])

        do {
            let loop = try await factory.makeLoop(sessionID: sessionID, cwd: cwd, mcpServers: mcpServers)
            addSession(sessionID, loop: loop, setup: SessionSetup(cwd: cwd, mcpServers: mcpServers))
            connectionStream.publish(
                .makeSuccess(id: request.id, result: .object(["sessionId": .string(sessionID)]))
            )
        } catch {
            connectionStream.publish(
                .makeError(id: request.id, code: .internalError, message: "session/new failed: \(error)")
            )
        }
    }

    /// Brings back a session, from memory or from its journal, and sends
    /// its conversation as `session/update` notifications before the reply,
    /// as the ACP spec asks.
    private func loadSession(request: JSONRPCRequest) async {
        let params = request.params?.objectValue ?? [:]
        guard capabilities.loadSession, let sessionID = params["sessionId"]?.stringValue else {
            connectionStream.publish(
                .makeError(id: request.id, code: .invalidParams, message: "session/load needs a sessionId and a server that keeps sessions")
            )
            return
        }
        let setup = SessionSetup(
            cwd: params["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath,
            mcpServers: decodeMCPServers(params["mcpServers"])
        )
        let session: ACPSession
        do {
            guard let found = try await liveSession(sessionID, setupIfUnknown: setup) else {
                connectionStream.publish(.makeError(id: request.id, code: .invalidParams, message: "session \(sessionID) not found"))
                return
            }
            session = found
        } catch {
            connectionStream.publish(.makeError(id: request.id, code: .internalError, message: "session/load failed: \(error)"))
            return
        }
        await session.sendHistory()
        connectionStream.publish(.makeSuccess(id: request.id, result: .object([:])))
    }

    private func prompt(request: JSONRPCRequest) async {
        guard let params = request.params?.objectValue,
              let sessionID = params["sessionId"]?.stringValue,
              let session = try? await liveSession(sessionID)
        else {
            connectionStream.publish(
                .makeError(id: request.id, code: .invalidParams, message: "unknown session")
            )
            return
        }
        let content = (params["prompt"]?.arrayValue ?? []).compactMap { ACPContentBlock(json: $0) }
        await session.prompt(requestID: request.id, content: content)
    }

    private func setModel(request: JSONRPCRequest) async {
        guard let params = request.params?.objectValue,
              let sessionID = params["sessionId"]?.stringValue,
              let modelID = params["modelId"]?.stringValue,
              let session = try? await liveSession(sessionID)
        else {
            connectionStream.publish(
                .makeError(id: request.id, code: .invalidParams, message: "session/set_model needs a known sessionId and a modelId")
            )
            return
        }
        await session.setModel(modelID)
        connectionStream.publish(.makeSuccess(id: request.id, result: .object([:])))
    }

    // MARK: - Sessions in memory

    private func addSession(_ sessionID: String, loop: AgentLoop, setup: SessionSetup) {
        let sink = ConnectionSink(connection: self)
        sessions[sessionID] = ACPSession(sessionID: sessionID, cwd: setup.cwd, loop: loop, sink: sink)
        setups[sessionID] = setup
        // Ensure the session stream exists.
        _ = sessionOutbound(for: sessionID)
    }

    /// The session, rebuilt from its journal when it was unloaded. A session
    /// this connection never had is restored only with `setupIfUnknown`
    /// (`session/load` says where it runs). Nil when there is none to find.
    private func liveSession(_ sessionID: String, setupIfUnknown: SessionSetup? = nil) async throws -> ACPSession? {
        if let session = sessions[sessionID] { return session }
        guard let setup = setups[sessionID] ?? setupIfUnknown else { return nil }
        guard let loop = try await factory.restoreLoop(sessionID: sessionID, cwd: setup.cwd, mcpServers: setup.mcpServers) else {
            return nil
        }
        // Another request may have restored it while this one waited.
        if let session = sessions[sessionID] { return session }
        addSession(sessionID, loop: loop, setup: setup)
        return sessions[sessionID]
    }

    /// Drops the sessions with no prompt running for `idle`: their loops,
    /// messages and MCP servers go, their ids stay, and the next request
    /// rebuilds them from their journals. Only when sessions can be loaded.
    public func unloadIdleSessions(idleFor idle: Duration) async {
        guard capabilities.loadSession else { return }
        for (sessionID, session) in sessions where await session.isIdle(for: idle) {
            sessions[sessionID] = nil
        }
    }

    /// Checks for idle sessions every minute (or `interval`) until the
    /// connection goes away.
    public func startUnloadingIdleSessions(after idle: Duration, checkingEvery interval: Duration = .seconds(60)) {
        idleSweeper?.cancel()
        idleSweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.unloadIdleSessions(idleFor: idle)
            }
        }
    }

    /// Whether `sessionID` is in memory now, for tests.
    func isLoaded(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    // MARK: - Helpers

    /// Decode the `mcpServers` array from a `session/new` params object.
    private func decodeMCPServers(_ value: JSON?) -> [MCPServerConfig] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { entry -> MCPServerConfig? in
            guard let obj = entry.objectValue, let command = obj["command"]?.stringValue else { return nil }
            let name = obj["name"]?.stringValue ?? command
            let args = obj["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let envDict = obj["env"]?.arrayValue?.compactMap { $0.objectValue }.flatMap { d -> [(String, String)] in
                d.compactMap { (k, v) in v.stringValue.map { (k, $0) } }
            } ?? []
            return MCPServerConfig(name: name, command: command, args: args, env: Dictionary(envDict, uniquingKeysWith: { _, b in b }))
        }
    }
}

/// A sink backed by an `ACPConnection`, routing messages to the right stream.
///
/// Lives in the connection's actor isolation: `send` hops onto the connection
/// to publish. This keeps the session's view of the transport tiny (just
/// "where do I send this?") and the connection's view of routing centralized.
public struct ConnectionSink: ACPMessageSink {
    private let connection: ACPConnection

    public init(connection: ACPConnection) {
        self.connection = connection
    }

    public func send(_ message: JSONRPCMessage, route: ACPRoute) async {
        await connection.publish(message, route: route)
    }
}

extension ACPConnection {
    /// Publish a message to the stream its route maps to under this
    /// connection's `routing`.
    public func publish(_ message: JSONRPCMessage, route: ACPRoute) async {
        switch (routing, route) {
        case (.singleStream, _), (.perSession, .connection):
            connectionStream.publish(message)
        case (.perSession, .session(let sessionID)):
            sessionStreams[sessionID]?.publish(message)
        }
    }
}
