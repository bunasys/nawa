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

    public init(
        hostname: String = "127.0.0.1",
        port: Int = 7878,
        info: ACPServerInfo = .nawa,
        capabilities: ACPCapabilities = .init(),
        idleSessionTimeout: Duration? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.info = info
        self.capabilities = capabilities
        self.idleSessionTimeout = idleSessionTimeout
    }
}

/// The ACP server: a Hummingbird application exposing the agent over the
/// streamable HTTP and WebSocket transports on a single port `/acp`.
///
/// Routing (per the streamable-http-websocket transport RFD):
/// - `POST /acp`: JSON-RPC. `initialize` returns 200 with a JSON body and the
///   `Acp-Connection-Id` header; all other requests return 202 Accepted
///   immediately and are processed async, with responses delivered later on the
///   matching GET stream (correlated by JSON-RPC id).
/// - `GET /acp` (no Upgrade): SSE. `Acp-Connection-Id` alone → stream for
///   connection-scoped messages; `Acp-Connection-Id` + `Acp-Session-Id` →
///   session-scoped stream.
/// - `GET /acp` with `Upgrade: websocket`: full-duplex WebSocket.
/// - `DELETE /acp`: terminate the connection (202).
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
        let router = Router(context: BasicRequestContext.self)
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)

        // POST /acp
        router.post("acp") { request, context -> Response in
            await self.handlePOST(request: request, context: context)
        }

        // GET /acp (SSE)
        router.get("acp") { request, context -> Response in
            await self.handleGET(request: request, context: context)
        }

        // DELETE /acp
        router.delete("acp") { request, context -> Response in
            await self.handleDELETE(request: request, context: context)
        }

        // WebSocket upgrade on /acp. The connection is created at upgrade time
        // so its id can be returned in the upgrade response headers.
        let socketBox = ACPSocketBox()
        wsRouter.ws("acp") { request, _ in
            guard request.headers[.upgrade]?.lowercased() == "websocket" else { return .dontUpgrade }
            let connection = await self.registry.createConnection(
                factory: self.factory,
                info: self.configuration.info,
                capabilities: self.configuration.capabilities,
                idleSessionTimeout: self.configuration.idleSessionTimeout,
                routing: .singleStream
            )
            socketBox.connection = connection
            var headers = HTTPFields()
            headers[.acpConnectionID] = connection.connectionID
            return .upgrade(headers)
        } onUpgrade: { inbound, outbound, context in
            guard let connection = socketBox.connection else { return }
            await self.handleWebSocket(inbound: inbound, outbound: outbound, connection: connection)
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(configuration.hostname, port: configuration.port),
                serverName: "swift-agent-acp"
            )
        )
        return app
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
            let connection = await registry.createConnection(
                factory: factory,
                info: configuration.info,
                capabilities: configuration.capabilities,
                idleSessionTimeout: configuration.idleSessionTimeout
            )
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

        // All other requests: 202 Accepted, process async.
        if case .request(let req) = message {
            let connectionID = request.headers[.acpConnectionID]
            if let connection = await registry.connection(for: connectionID) {
                let reqCopy = req
                Task { await connection.handle(.request(reqCopy)) }
            }
        }
        return Response(status: .accepted)
    }

    // MARK: - GET (SSE)

    private func handleGET(request: Request, context: BasicRequestContext) async -> Response {
        let connectionID = request.headers[.acpConnectionID]
        let sessionID = request.headers[.acpSessionID]
        guard let connection = await registry.connection(for: connectionID) else {
            return Response(status: .badRequest)
        }

        let stream: AsyncStream<JSONRPCMessage>
        if let sessionID {
            stream = await connection.sessionOutbound(for: sessionID)
        } else {
            stream = await connection.outbound
        }

        return Response(
            status: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
            body: .init(contentLength: nil) { writer in
                let allocator = ByteBufferAllocator()
                for await message in stream {
                    let frame = "data: \(message.json.description)\n\n"
                    var buffer = allocator.buffer(capacity: frame.utf8.count)
                    buffer.writeString(frame)
                    try await writer.write(buffer)
                }
                try await writer.finish(nil)
            }
        )
    }

    // MARK: - DELETE

    private func handleDELETE(request: Request, context: BasicRequestContext) async -> Response {
        let connectionID = request.headers[.acpConnectionID]
        await registry.removeConnection(connectionID)
        return Response(status: .accepted)
    }

    // MARK: - WebSocket

    private func handleWebSocket(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        connection: ACPConnection
    ) async {
        let outboundTask = Task {
            // Stream connection-scoped messages to the socket.
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
        await registry.removeConnection(connection.connectionID)
    }
}

/// Holds the connection created during a WebSocket upgrade so the handshake
/// decision and the upgraded-socket closures can share it.
final class ACPSocketBox: @unchecked Sendable {
    var connection: ACPConnection?
    init() {}
}

/// Registry of active connections, keyed by `Acp-Connection-Id`.
public actor ACPRegistry {
    private var connections: [String: ACPConnection] = [:]

    public init() {}

    public func createConnection(
        factory: any ACPSessionFactory,
        info: ACPServerInfo,
        capabilities: ACPCapabilities,
        idleSessionTimeout: Duration? = nil,
        routing: ACPOutboundRouting = .perSession
    ) async -> ACPConnection {
        let id = "conn_\(UUID().uuidString.prefix(12))"
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

    public func removeConnection(_ id: String?) {
        guard let id else { return }
        connections.removeValue(forKey: id)
    }
}
