import AgentCore
import AgentJSONRPC
import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import HTTPTypes
import NIOCore

/// Custom HTTP field names used by the ACP streamable transport.
extension HTTPField.Name {
    /// Identifies an ACP connection across requests.
    public static var acpConnectionID: Self { Self("Acp-Connection-Id")! }
    /// Identifies which session a request/stream targets.
    public static var acpSessionID: Self { Self("Acp-Session-Id")! }
}

/// Configuration for the ACP server.
public struct ACPServerConfiguration: Sendable {
    public var hostname: String
    public var port: Int
    public var info: ACPServerInfo
    public var capabilities: ACPCapabilities
    /// Unload a session after this long without a prompt, keeping only its
    /// id; it is rebuilt from its journal when needed. Needs
    /// `capabilities.loadSession`. Nil keeps every session in memory.
    public var idleSessionTimeout: Duration?
    /// Web origins (`https://app.example`) whose pages may use the server.
    /// Empty by default: native ACP clients send no `Origin`, browsers
    /// always do on a WebSocket, and a page that can reach the server can
    /// start MCP servers, that is, run commands.
    public var allowedOrigins: Set<String>
    /// When set, every request must carry `Authorization: Bearer <token>`,
    /// and any `Host` is accepted: a remote client names the machine its
    /// own way, and the token, not the name, keeps strangers out. Nil
    /// (the default) admits only local names, for a server on loopback.
    public var bearerToken: String?

    public init(
        hostname: String = "127.0.0.1",
        port: Int = 7878,
        info: ACPServerInfo = .nawa,
        capabilities: ACPCapabilities = .init(),
        idleSessionTimeout: Duration? = nil,
        allowedOrigins: Set<String> = [],
        bearerToken: String? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.info = info
        self.capabilities = capabilities
        self.idleSessionTimeout = idleSessionTimeout
        self.allowedOrigins = allowedOrigins
        self.bearerToken = bearerToken
    }

    /// Whether a request with this `Host` (`authority`), `Origin` and
    /// `Authorization` may reach the agent.
    /// - The `Origin` check stops any web page opening a WebSocket to the
    ///   server, which browsers allow.
    /// - With a `bearerToken`, the token must match.
    /// - Without one, the `Host` check stops DNS rebinding (a page whose own
    ///   domain resolves to 127.0.0.1).
    public func admission(authority: String?, origin: String?, authorization: String?) -> ACPAdmission {
        if let origin {
            // Browsers send the page's origin (http, https or "null"). A ws://
            // or wss:// one comes from a native WebSocket client, never a page:
            // swift-websocket's client (`nawa connect`) always sends one.
            let scheme = origin.lowercased()
            let fromNativeClient = scheme.hasPrefix("ws://") || scheme.hasPrefix("wss://")
            let isAllowedPage = allowedOrigins.contains(origin)
            if !fromNativeClient && !isAllowedPage { return .forbidden }
        }

        if let bearerToken {
            let presented = Self.token(inAuthorization: authorization)
            guard let presented, Self.constantTimeEquals(presented, bearerToken) else { return .unauthorized }
            return .admitted
        }

        guard let authority else { return .forbidden }
        let host = Self.hostName(ofAuthority: authority.lowercased())
        let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "[::1]"]
        let isIPv6Address = hostname.contains(":")
        let boundName = isIPv6Address ? "[\(hostname.lowercased())]" : hostname.lowercased()
        let isLocalName = loopbackNames.contains(host) || host == boundName
        return isLocalName ? .admitted : .forbidden
    }

    /// `Bearer abc` → `abc`. Nil for any other scheme or an empty token, so
    /// an empty configured token admits no one.
    private static func token(inAuthorization authorization: String?) -> String? {
        guard let authorization else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Compares every byte whatever the first difference, so the time a
    /// wrong guess takes says nothing about how much of it was right.
    static func constantTimeEquals(_ presented: String, _ expected: String) -> Bool {
        let presentedBytes = Array(presented.utf8)
        let expectedBytes = Array(expected.utf8)
        var difference: UInt8 = presentedBytes.count == expectedBytes.count ? 0 : 1
        for index in 0..<max(presentedBytes.count, expectedBytes.count) {
            let left = index < presentedBytes.count ? presentedBytes[index] : 0
            let right = index < expectedBytes.count ? expectedBytes[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    /// `localhost:7878` → `localhost`, `[::1]:7878` → `[::1]`.
    private static func hostName(ofAuthority authority: String) -> String {
        if authority.hasPrefix("["), let end = authority.firstIndex(of: "]") {
            return String(authority[...end])
        }
        return String(authority.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

/// What `ACPServerConfiguration.admission` decides about a request.
public enum ACPAdmission: Sendable, Equatable {
    case admitted
    /// A web page or a foreign `Host`: 403.
    case forbidden
    /// A missing or wrong bearer token: 401.
    case unauthorized
}

/// Answers 403 or 401 to a request `ACPServerConfiguration.admission`
/// turns away. On both routers. On the WebSocket router it refuses the
/// handshake, which Hummingbird always answers with its own 400.
struct ACPAdmissionMiddleware<Context: RequestContext>: RouterMiddleware {
    let configuration: ACPServerConfiguration

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let admission = configuration.admission(
            authority: request.head.authority,
            origin: request.headers[.origin],
            authorization: request.headers[.authorization]
        )
        switch admission {
        case .admitted:
            return try await next(request, context)
        case .forbidden:
            return Response(status: .forbidden)
        case .unauthorized:
            return Response(status: .unauthorized, headers: [.wwwAuthenticate: "Bearer"])
        }
    }
}

/// The WebSocket router's request context. It names the connection during
/// the handshake, so the upgrade response can carry the id and the
/// upgraded socket can create the connection under it: each socket gets
/// its own, however many handshakes run at once.
struct ACPWebSocketRequestContext: RequestContext, WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    let connectionID: String

    init(source: Source) {
        coreContext = .init(source: source)
        webSocket = .init()
        connectionID = ACPRegistry.newConnectionID()
    }
}

/// The ACP server: a Hummingbird application exposing the agent over the
/// streamable HTTP and WebSocket transports on a single port `/acp`.
///
/// Routing (per the streamable-http-websocket transport RFD):
/// - `POST /acp`: JSON-RPC. `initialize` returns 200 with a JSON body and the
///   `Acp-Connection-Id` header; every other message returns 202 Accepted
///   immediately and is processed async, with responses delivered later on
///   the matching GET stream (correlated by JSON-RPC id).
/// - `GET /acp` (no Upgrade): SSE. `Acp-Connection-Id` alone → stream for
///   connection-scoped messages; `Acp-Connection-Id` + `Acp-Session-Id` →
///   session-scoped stream. One reader per stream (409 for a second).
/// - `GET /acp` with `Upgrade: websocket`: full-duplex WebSocket.
/// - `DELETE /acp`: terminate the connection (202).
///
/// Every route refuses requests from web pages and foreign hosts (403),
/// and, when the configuration has a `bearerToken`, requests without it
/// (401; a refused WebSocket handshake is Hummingbird's 400). See
/// `ACPServerConfiguration.admission`.
public struct ACPServer: Sendable {
    public let configuration: ACPServerConfiguration
    public let factory: any ACPSessionFactory
    private let registry: ACPRegistry

    public init(configuration: ACPServerConfiguration = .init(), factory: any ACPSessionFactory) {
        self.configuration = configuration
        self.factory = factory
        self.registry = ACPRegistry()
    }

    /// Build the Hummingbird application.
    public func buildApplication() -> some ApplicationProtocol {
        buildApplication(onServerRunning: { _ in })
    }

    /// `onServerRunning` gets the listening channel, whose `localAddress`
    /// is the port actually bound (port 0 picks a free one).
    public func buildApplication(onServerRunning: @escaping @Sendable (any Channel) async -> Void) -> some ApplicationProtocol {
        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: ACPAdmissionMiddleware(configuration: configuration))
        router.post("acp") { request, context -> Response in
            await self.handlePOST(request: request, context: context)
        }
        router.get("acp") { request, context -> Response in
            await self.handleGET(request: request, context: context)
        }
        router.delete("acp") { request, context -> Response in
            await self.handleDELETE(request: request, context: context)
        }

        let wsRouter = Router(context: ACPWebSocketRequestContext.self)
        wsRouter.add(middleware: ACPAdmissionMiddleware(configuration: configuration))
        wsRouter.ws("acp") { request, context in
            guard request.headers[.upgrade]?.lowercased() == "websocket" else { return .dontUpgrade }
            var headers = HTTPFields()
            headers[.acpConnectionID] = context.connectionID
            return .upgrade(headers)
        } onUpgrade: { inbound, outbound, context in
            await self.handleWebSocket(inbound: inbound, outbound: outbound, connectionID: context.requestContext.connectionID)
        }

        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(configuration.hostname, port: configuration.port),
                serverName: "swift-agent-acp"
            ),
            onServerRunning: onServerRunning
        )
    }

    private func makeConnection(id: String? = nil, routing: ACPOutboundRouting) async -> ACPConnection {
        await registry.createConnection(
            id: id,
            factory: factory,
            info: configuration.info,
            capabilities: configuration.capabilities,
            idleSessionTimeout: configuration.idleSessionTimeout,
            routing: routing
        )
    }

    // MARK: - POST

    private func handlePOST(request: Request, context: BasicRequestContext) async -> Response {
        var mutableRequest = request
        let body: Data
        do {
            let buffer = try await mutableRequest.collectBody(upTo: 1_000_000)
            body = Data(buffer.readableBytesView)
        } catch {
            return Response(status: .badRequest)
        }

        let message: JSONRPCMessage
        do {
            message = try parseJSONRPCLine(String(decoding: body, as: UTF8.self))
        } catch {
            return Response(status: .badRequest)
        }

        // `initialize` is special: return 200 with JSON body + Acp-Connection-Id header.
        if case .request(let req) = message, req.method == "initialize" {
            let connection = await makeConnection(routing: .perSession)
            let result = await connection.initializeResult()
            let responseMessage = JSONRPCMessage.makeSuccess(id: req.id, result: result)
            let data = Data(responseMessage.json.description.utf8)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/json",
                    .acpConnectionID: connection.connectionID,
                ],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        // Everything else, notifications (`session/cancel`) included:
        // 202 Accepted, processed async.
        guard let connection = await registry.connection(for: request.headers[.acpConnectionID]) else {
            return Response(status: .notFound)
        }
        Task { await connection.handle(message) }
        return Response(status: .accepted)
    }

    // MARK: - GET (SSE)

    private func handleGET(request: Request, context: BasicRequestContext) async -> Response {
        guard let connection = await registry.connection(for: request.headers[.acpConnectionID]) else {
            return Response(status: .notFound)
        }
        let route: ACPRoute = request.headers[.acpSessionID].map { .session($0) } ?? .connection

        let stream: AsyncStream<JSONRPCMessage>
        switch await connection.attachStream(route) {
        case .stream(let attached):
            stream = attached
        case .alreadyAttached:
            return Response(status: .conflict)
        case .unknownSession:
            return Response(status: .notFound)
        }

        return Response(
            status: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
            body: .init(contentLength: nil) { writer in
                do {
                    let allocator = ByteBufferAllocator()
                    for await message in stream {
                        let frame = "data: \(message.json.description)\n\n"
                        var buffer = allocator.buffer(capacity: frame.utf8.count)
                        buffer.writeString(frame)
                        try await writer.write(buffer)
                    }
                    try await writer.finish(nil)
                } catch {
                    await connection.detachStream(route)
                    throw error
                }
                await connection.detachStream(route)
            }
        )
    }

    // MARK: - DELETE

    private func handleDELETE(request: Request, context: BasicRequestContext) async -> Response {
        guard let connection = await registry.removeConnection(request.headers[.acpConnectionID]) else {
            return Response(status: .notFound)
        }
        await connection.close()
        return Response(status: .accepted)
    }

    // MARK: - WebSocket

    private func handleWebSocket(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        connectionID: String
    ) async {
        let connection = await makeConnection(id: connectionID, routing: .singleStream)
        let outboundTask = Task {
            for await message in await connection.outbound {
                try? await outbound.write(.text(message.json.description))
            }
        }
        do {
            for try await wsMessage in inbound.messages(maxSize: 1_000_000) {
                guard case .text(let text) = wsMessage else { continue }
                await connection.handle(text: text)
            }
        } catch {
            // socket closed
        }
        outboundTask.cancel()
        await outboundTask.value
        await registry.removeConnection(connectionID)
        await connection.close()
    }
}

/// Registry of active connections, keyed by `Acp-Connection-Id`.
public actor ACPRegistry {
    private var connections: [String: ACPConnection] = [:]

    public init() {}

    static func newConnectionID() -> String {
        "conn_\(UUID().uuidString.prefix(12))"
    }

    public func createConnection(
        id: String? = nil,
        factory: any ACPSessionFactory,
        info: ACPServerInfo,
        capabilities: ACPCapabilities,
        idleSessionTimeout: Duration? = nil,
        routing: ACPOutboundRouting = .perSession
    ) async -> ACPConnection {
        let id = id ?? Self.newConnectionID()
        let connection = ACPConnection(
            connectionID: id, factory: factory, info: info, capabilities: capabilities, routing: routing
        )
        if let idleSessionTimeout {
            await connection.startUnloadingIdleSessions(after: idleSessionTimeout)
        }
        connections[id] = connection
        return connection
    }

    public func connection(for id: String?) -> ACPConnection? {
        guard let id else { return nil }
        return connections[id]
    }

    /// Forgets the connection and returns it, for its caller to close.
    @discardableResult
    public func removeConnection(_ id: String?) -> ACPConnection? {
        guard let id else { return nil }
        return connections.removeValue(forKey: id)
    }
}
