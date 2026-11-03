import AgentCore
import AgentJSONRPC
import AgentLoop
import AgentMCP
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

/// What an SSE GET gets when it asks for a stream.
enum ACPStreamAttachment {
    case stream(AsyncStream<JSONRPCMessage>)
    /// Another GET already reads this stream, and a stream has one reader.
    case alreadyAttached
    /// The session the GET names doesn't exist on this connection.
    case unknownSession
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

    private var connectionStream = ACPEventStream()
    private var sessionStreams: [String: ACPEventStream] = [:]
    /// The streams an SSE GET is reading now.
    private var attachedStreams: Set<ACPRoute> = []
    /// Sessions in memory. An idle one may be dropped from here and rebuilt
    /// from its journal on its next request (see `unloadIdleSessions`).
    private var sessions: [String: ACPSession] = [:]
    /// How every session of this connection was set up, loaded or not.
    private var setups: [String: SessionSetup] = [:]
    /// When each session was last sent a prompt, noted before any await so
    /// the idle sweeper can see a prompt that is still on its way.
    private var lastPromptAt: [String: ContinuousClock.Instant] = [:]
    /// Restores in progress. Requests for the same unloaded session share
    /// one: a second restore would find the journal locked by the first.
    private var restoring: [String: Task<ACPSession?, any Error>] = [:]
    private var idleSweeper: Task<Void, Never>?
    private var isClosed = false

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

    /// The connection-scoped outbound stream, for transports with one pipe
    /// (stdio, WebSocket). SSE GETs use `attachStream`.
    public var outbound: AsyncStream<JSONRPCMessage> { connectionStream.stream }

    /// Ends the connection: stops the idle sweeper, cancels running prompts,
    /// lets the sessions go (their MCP servers stop with them) and ends the
    /// outbound streams once what is already queued on them has been read.
    /// Later messages are dropped.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        idleSweeper?.cancel()
        let closing = Array(sessions.values)
        sessions = [:]
        for session in closing { await session.cancel() }
        connectionStream.finish()
        for stream in sessionStreams.values { stream.finish() }
    }

    /// The stream an SSE GET reads: the connection's, or a session's. Each
    /// has one reader at a time; `detachStream` lets the next one in.
    func attachStream(_ route: ACPRoute) -> ACPStreamAttachment {
        guard !attachedStreams.contains(route) else { return .alreadyAttached }
        let stream: ACPEventStream
        switch route {
        case .connection:
            stream = connectionStream
        case .session(let sessionID):
            guard let sessionStream = sessionStreams[sessionID] else { return .unknownSession }
            stream = sessionStream
        }
        attachedStreams.insert(route)
        return .stream(stream.stream)
    }

    /// The SSE GET reading `route` has ended.
    func detachStream(_ route: ACPRoute) {
        attachedStreams.remove(route)
        guard !isClosed else { return }
        // A stream ends when its reader goes away, so a reconnecting GET
        // needs a fresh one.
        switch route {
        case .connection:
            connectionStream = ACPEventStream()
        case .session(let sessionID):
            sessionStreams[sessionID] = ACPEventStream()
        }
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

    /// Handle an inbound JSON-RPC message. Responses are ignored: the agent
    /// sends the client no requests.
    public func handle(_ message: JSONRPCMessage) async {
        guard !isClosed else { return }
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
        let mcpServers = Self.decodeMCPServers(params.objectValue?["mcpServers"])

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
            mcpServers: Self.decodeMCPServers(params["mcpServers"])
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
        // The replay would interleave with the running turn's updates.
        guard await !session.isRunning else {
            connectionStream.publish(.makeError(id: request.id, code: .invalidRequest, message: "session \(sessionID) is running a prompt; load it once the turn ends"))
            return
        }
        await session.sendHistory()
        connectionStream.publish(.makeSuccess(id: request.id, result: .object([:])))
    }

    private func prompt(request: JSONRPCRequest) async {
        let params = request.params?.objectValue ?? [:]
        let sessionID = params["sessionId"]?.stringValue
        if let sessionID { lastPromptAt[sessionID] = .now }
        guard let session = await liveSession(sessionID, answering: request) else { return }
        let content = (params["prompt"]?.arrayValue ?? []).compactMap { ACPContentBlock(json: $0) }
        await session.prompt(requestID: request.id, content: content)
    }

    private func setModel(request: JSONRPCRequest) async {
        let params = request.params?.objectValue ?? [:]
        guard let modelID = params["modelId"]?.stringValue else {
            connectionStream.publish(.makeError(id: request.id, code: .invalidParams, message: "session/set_model needs a modelId"))
            return
        }
        guard let session = await liveSession(params["sessionId"]?.stringValue, answering: request) else { return }
        await session.setModel(modelID)
        connectionStream.publish(.makeSuccess(id: request.id, result: .object([:])))
    }

    /// The request's session, rebuilt if it was unloaded. When there is
    /// none, answers `request` and returns nil: `unknown session` for an id
    /// this connection doesn't know, the error itself when rebuilding a
    /// known one failed (a broken config must not look like a lost session).
    private func liveSession(_ sessionID: String?, answering request: JSONRPCRequest) async -> ACPSession? {
        do {
            if let sessionID, let session = try await liveSession(sessionID) { return session }
            connectionStream.publish(.makeError(id: request.id, code: .invalidParams, message: "unknown session"))
        } catch {
            connectionStream.publish(.makeError(id: request.id, code: .internalError, message: "could not restore the session: \(error)"))
        }
        return nil
    }

    // MARK: - Sessions in memory

    private func addSession(_ sessionID: String, loop: AgentLoop, setup: SessionSetup) {
        let sink = ConnectionSink(connection: self)
        sessions[sessionID] = ACPSession(sessionID: sessionID, cwd: setup.cwd, loop: loop, sink: sink)
        setups[sessionID] = setup
        if sessionStreams[sessionID] == nil {
            sessionStreams[sessionID] = ACPEventStream()
        }
    }

    /// The session, rebuilt from its journal when it was unloaded. A session
    /// this connection never had is restored only with `setupIfUnknown`
    /// (`session/load` says where it runs). Nil when there is none to find.
    private func liveSession(_ sessionID: String, setupIfUnknown: SessionSetup? = nil) async throws -> ACPSession? {
        if let session = sessions[sessionID] { return session }
        if let restore = restoring[sessionID] { return try await restore.value }
        guard let setup = setups[sessionID] ?? setupIfUnknown else { return nil }
        let restore = Task { () async throws -> ACPSession? in
            guard let loop = try await factory.restoreLoop(sessionID: sessionID, cwd: setup.cwd, mcpServers: setup.mcpServers) else {
                return nil
            }
            addSession(sessionID, loop: loop, setup: setup)
            return sessions[sessionID]
        }
        restoring[sessionID] = restore
        defer { restoring[sessionID] = nil }
        return try await restore.value
    }

    /// Drops the sessions with no prompt running for `idle`: their loops,
    /// messages and MCP servers go, their ids stay, and the next request
    /// rebuilds them from their journals. Only when sessions can be loaded.
    public func unloadIdleSessions(idleFor idle: Duration) async {
        guard capabilities.loadSession else { return }
        for (sessionID, session) in sessions where await session.isIdle(for: idle) {
            // A prompt may have reached this connection while `isIdle` was
            // awaited, and not reached the session yet.
            let stillInMemory = sessions[sessionID] === session
            let promptedRecently = lastPromptAt[sessionID].map { ContinuousClock.now - $0 < idle } ?? false
            guard stillInMemory, !promptedRecently else { continue }
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

    /// Decode the `mcpServers` array of `session/new` / `session/load`.
    /// Only stdio servers (with a `command`) can be run; the others are
    /// reported on stderr, never stdout, which carries the protocol in
    /// stdio mode.
    static func decodeMCPServers(_ value: JSON?) -> [MCPServerConfig] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.compactMap { entry -> MCPServerConfig? in
            guard let server = entry.objectValue else { return nil }
            let name = server["name"]?.stringValue
            guard let command = server["command"]?.stringValue else {
                let kind = server["type"]?.stringValue ?? "unknown"
                FileHandle.standardError.write(Data("nawa: skipping MCP server \(name ?? "?"): \(kind) servers are not supported, only stdio\n".utf8))
                return nil
            }
            let args = server["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            // ACP sends the environment as `[{"name": …, "value": …}]`.
            var env: [String: String] = [:]
            for variable in server["env"]?.arrayValue ?? [] {
                let fields = variable.objectValue
                guard let variableName = fields?["name"]?.stringValue,
                      let variableValue = fields?["value"]?.stringValue
                else { continue }
                env[variableName] = variableValue
            }
            return MCPServerConfig(name: name ?? command, command: command, args: args, env: env)
        }
    }
}

/// A sink backed by an `ACPConnection`, routing messages to the right stream.
///
/// Holds the connection weakly: the connection owns its sessions, so a
/// strong reference back would keep both alive forever. Messages sent after
/// the connection is gone are dropped.
public struct ConnectionSink: ACPMessageSink {
    private weak let connection: ACPConnection?

    public init(connection: ACPConnection) {
        self.connection = connection
    }

    public func send(_ message: JSONRPCMessage, route: ACPRoute) async {
        await connection?.publish(message, route: route)
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
