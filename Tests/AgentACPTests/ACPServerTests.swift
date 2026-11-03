@testable import AgentACP
import Dispatch
import Foundation
import Synchronization
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One TCP connection to a test server, speaking raw HTTP/1.1, so a test
/// can send any `Host` or `Origin` (URLSession won't let it set `Host`).
/// Reads block, so they run off the Swift concurrency pool.
final class RawHTTPConnection: @unchecked Sendable {
    private let socketFD: Int32

    init(port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", String(port), &hints, &found) == 0, let address = found?.pointee else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        defer { freeaddrinfo(found) }
        socketFD = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard connect(socketFD, address.ai_addr, address.ai_addrlen) == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(socketFD) }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { writeToSocket(socketFD, $0.baseAddress, bytes.count) }
    }

    /// What arrives until `needle` does, the server closes, or 10 s pass.
    func read(until needle: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var received = ""
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !received.contains(needle) {
                    let count = recv(self.socketFD, &buffer, buffer.count, 0)
                    guard count > 0 else { break }
                    received += String(decoding: buffer[0..<count], as: UTF8.self)
                }
                continuation.resume(returning: received)
            }
        }
    }

    /// Sends a request and returns the response head and as much of the
    /// body as arrived with it (or until `until`).
    func request(_ method: String, host: String, headers: [String: String] = [:], body: String = "", until: String = "\r\n\r\n") async -> String {
        var lines = ["\(method) /acp HTTP/1.1", "Host: \(host)", "Content-Length: \(body.utf8.count)"]
        lines += headers.map { "\($0.key): \($0.value)" }
        send(lines.joined(separator: "\r\n") + "\r\n\r\n" + body)
        return await read(until: until)
    }
}

private func writeToSocket(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    Glibc.send(fd, pointer, count, 0)
    #else
    Darwin.send(fd, pointer, count, 0)
    #endif
}

/// Runs an ACP server on a free port for the length of `body`.
func withACPServer(
    factory: any ACPSessionFactory = HangingFactory(),
    _ body: @Sendable (Int) async throws -> Void
) async throws {
    let server = ACPServer(configuration: ACPServerConfiguration(port: 0), factory: factory)
    let (ports, portContinuation) = AsyncStream<Int>.makeStream()
    let app = server.buildApplication { channel in
        if let port = channel.localAddress?.port { portContinuation.yield(port) }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService(gracefulShutdownSignals: []) }
        var waitingForPort = ports.makeAsyncIterator()
        let port = try #require(await waitingForPort.next())
        try await body(port)
        group.cancelAll()
    }
}

private func statusLine(_ response: String) -> String {
    response.components(separatedBy: "\r\n").first ?? ""
}

private func header(_ name: String, in response: String) -> String? {
    let prefix = name.lowercased() + ":"
    let line = response.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(prefix) }
    return line.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
}

private let initializeBody = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#
private let webSocketUpgrade = [
    "Upgrade": "websocket",
    "Connection": "Upgrade",
    "Sec-WebSocket-Version": "13",
    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
]

@Suite(.timeLimit(.minutes(1)))
struct ACPServerAdmissionTests {
    @Test
    func localNamesAndTheBoundAddressAreAdmitted() {
        let local = ACPServerConfiguration()
        #expect(local.admits(authority: "127.0.0.1:7878", origin: nil))
        #expect(local.admits(authority: "localhost", origin: nil))
        #expect(local.admits(authority: "[::1]:7878", origin: nil))
        #expect(!local.admits(authority: "evil.example:7878", origin: nil))
        #expect(!local.admits(authority: "localhost.evil.example", origin: nil))
        #expect(!local.admits(authority: nil, origin: nil))

        let lan = ACPServerConfiguration(hostname: "192.168.1.5")
        #expect(lan.admits(authority: "192.168.1.5:7878", origin: nil))
    }

    @Test
    func webOriginsAreRefusedUnlessAllowed() {
        #expect(!ACPServerConfiguration().admits(authority: "127.0.0.1:7878", origin: "https://evil.example"))
        let allowing = ACPServerConfiguration(allowedOrigins: ["https://app.example"])
        #expect(allowing.admits(authority: "127.0.0.1:7878", origin: "https://app.example"))
        #expect(!allowing.admits(authority: "127.0.0.1:7878", origin: "https://evil.example"))
    }

    @Test
    func aLocalClientCanInitialize() async throws {
        try await withACPServer { port in
            let response = try await RawHTTPConnection(port: port).request("POST", host: "127.0.0.1:\(port)", body: initializeBody)
            #expect(statusLine(response) == "HTTP/1.1 200 OK")
            #expect(header("Acp-Connection-Id", in: response) != nil)
        }
    }

    @Test
    func aWebPageIsRefused() async throws {
        try await withACPServer { port in
            let post = try await RawHTTPConnection(port: port).request(
                "POST", host: "127.0.0.1:\(port)", headers: ["Origin": "https://evil.example"], body: initializeBody
            )
            #expect(statusLine(post).hasPrefix("HTTP/1.1 403"))

            var upgradeFromPage = webSocketUpgrade
            upgradeFromPage["Origin"] = "https://evil.example"
            // Hummingbird answers every refused handshake with 400.
            let upgrade = try await RawHTTPConnection(port: port).request("GET", host: "127.0.0.1:\(port)", headers: upgradeFromPage)
            #expect(statusLine(upgrade).hasPrefix("HTTP/1.1 400"))

            let stream = try await RawHTTPConnection(port: port).request(
                "GET", host: "127.0.0.1:\(port)", headers: ["Origin": "https://evil.example", "Acp-Connection-Id": "conn_any"]
            )
            #expect(statusLine(stream).hasPrefix("HTTP/1.1 403"))
        }
    }

    /// DNS rebinding: a page on evil.example whose name now resolves to 127.0.0.1.
    @Test
    func aForeignHostIsRefused() async throws {
        try await withACPServer { port in
            let response = try await RawHTTPConnection(port: port).request("POST", host: "evil.example:\(port)", body: initializeBody)
            #expect(statusLine(response).hasPrefix("HTTP/1.1 403"))
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPServerTransportTests {
    @Test
    func eachWebSocketGetsItsOwnConnection() async throws {
        try await withACPServer { port in
            let first = try RawHTTPConnection(port: port)
            let second = try RawHTTPConnection(port: port)
            let firstResponse = await first.request("GET", host: "127.0.0.1:\(port)", headers: webSocketUpgrade)
            let secondResponse = await second.request("GET", host: "127.0.0.1:\(port)", headers: webSocketUpgrade)
            #expect(statusLine(firstResponse).hasPrefix("HTTP/1.1 101"))
            #expect(statusLine(secondResponse).hasPrefix("HTTP/1.1 101"))
            let firstID = try #require(header("Acp-Connection-Id", in: firstResponse))
            #expect(firstID != header("Acp-Connection-Id", in: secondResponse))
        }
    }

    /// The streamable HTTP flow end to end: `session/cancel` is a
    /// notification, and must reach the session like any request.
    @Test
    func cancelOverHTTPEndsTheTurn() async throws {
        try await withACPServer { port in
            let host = "127.0.0.1:\(port)"
            let initialize = try await RawHTTPConnection(port: port).request("POST", host: host, body: initializeBody)
            let connectionID = try #require(header("Acp-Connection-Id", in: initialize))
            let onConnection = ["Acp-Connection-Id": connectionID]

            let connectionStream = try RawHTTPConnection(port: port)
            _ = await connectionStream.request("GET", host: host, headers: onConnection)
            let secondReader = try await RawHTTPConnection(port: port).request("GET", host: host, headers: onConnection)
            #expect(statusLine(secondReader).hasPrefix("HTTP/1.1 409"))

            let newSession = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#
            _ = try await RawHTTPConnection(port: port).request("POST", host: host, headers: onConnection, body: newSession)
            let created = await connectionStream.read(until: "sess_")
            let sessionID = try #require(created.firstMatch(of: /sess_[0-9A-F-]+/).map { String($0.output) })

            var onSession = onConnection
            onSession["Acp-Session-Id"] = sessionID
            let sessionStream = try RawHTTPConnection(port: port)
            _ = await sessionStream.request("GET", host: host, headers: onSession)

            let prompt = #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"\#(sessionID)","prompt":[{"type":"text","text":"hang"}]}}"#
            _ = try await RawHTTPConnection(port: port).request("POST", host: host, headers: onConnection, body: prompt)
            let cancel = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"\#(sessionID)"}}"#
            let cancelResponse = try await RawHTTPConnection(port: port).request("POST", host: host, headers: onConnection, body: cancel)
            #expect(statusLine(cancelResponse).hasPrefix("HTTP/1.1 202"))

            let answer = await sessionStream.read(until: "cancelled")
            #expect(answer.contains(#""stopReason":"cancelled""#))

            let unknownSession = try await RawHTTPConnection(port: port).request(
                "GET", host: host, headers: ["Acp-Connection-Id": connectionID, "Acp-Session-Id": "sess_made_up"]
            )
            #expect(statusLine(unknownSession).hasPrefix("HTTP/1.1 404"))
            let unknownConnection = try await RawHTTPConnection(port: port).request(
                "POST", host: host, headers: ["Acp-Connection-Id": "conn_made_up"], body: cancel
            )
            #expect(statusLine(unknownConnection).hasPrefix("HTTP/1.1 404"))
        }
    }
}
