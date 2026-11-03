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
    configuration: ACPServerConfiguration = ACPServerConfiguration(port: 0),
    factory: any ACPSessionFactory = HangingFactory(),
    _ body: @Sendable (Int) async throws -> Void
) async throws {
    let server = ACPServer(configuration: configuration, factory: factory)
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
        #expect(local.admission(authority: "127.0.0.1:7878", origin: nil, authorization: nil) == .admitted)
        #expect(local.admission(authority: "localhost", origin: nil, authorization: nil) == .admitted)
        #expect(local.admission(authority: "[::1]:7878", origin: nil, authorization: nil) == .admitted)
        #expect(local.admission(authority: "evil.example:7878", origin: nil, authorization: nil) == .forbidden)
        #expect(local.admission(authority: "localhost.evil.example", origin: nil, authorization: nil) == .forbidden)
        #expect(local.admission(authority: nil, origin: nil, authorization: nil) == .forbidden)

        let lan = ACPServerConfiguration(hostname: "192.168.1.5")
        #expect(lan.admission(authority: "192.168.1.5:7878", origin: nil, authorization: nil) == .admitted)
    }

    @Test
    func webOriginsAreRefusedUnlessAllowed() {
        let local = ACPServerConfiguration()
        #expect(local.admission(authority: "127.0.0.1:7878", origin: "https://evil.example", authorization: nil) == .forbidden)
        #expect(local.admission(authority: "127.0.0.1:7878", origin: "null", authorization: nil) == .forbidden)
        // What swift-websocket's client (`nawa connect`) sends; no page has it.
        #expect(local.admission(authority: "127.0.0.1:7878", origin: "ws://127.0.0.1", authorization: nil) == .admitted)
        let allowing = ACPServerConfiguration(allowedOrigins: ["https://app.example"])
        #expect(allowing.admission(authority: "127.0.0.1:7878", origin: "https://app.example", authorization: nil) == .admitted)
        #expect(allowing.admission(authority: "127.0.0.1:7878", origin: "https://evil.example", authorization: nil) == .forbidden)
    }

    @Test
    func aTokenIsRequiredAndThenAnyHostWillDo() {
        let remote = ACPServerConfiguration(hostname: "0.0.0.0", bearerToken: "s3cret")
        #expect(remote.admission(authority: "devbox.lan:7878", origin: nil, authorization: "Bearer s3cret") == .admitted)
        #expect(remote.admission(authority: "devbox.lan:7878", origin: nil, authorization: "bearer s3cret") == .admitted)
        #expect(remote.admission(authority: "127.0.0.1:7878", origin: nil, authorization: nil) == .unauthorized)
        #expect(remote.admission(authority: "devbox.lan:7878", origin: nil, authorization: "Bearer s3cre") == .unauthorized)
        #expect(remote.admission(authority: "devbox.lan:7878", origin: nil, authorization: "Basic s3cret") == .unauthorized)
        #expect(remote.admission(authority: "devbox.lan:7878", origin: "https://evil.example", authorization: "Bearer s3cret") == .forbidden)

        let empty = ACPServerConfiguration(bearerToken: "")
        #expect(empty.admission(authority: "127.0.0.1:7878", origin: nil, authorization: "Bearer ") == .unauthorized)
    }

    @Test
    func tokensCompareByContent() {
        #expect(ACPServerConfiguration.constantTimeEquals("abc", "abc"))
        #expect(!ACPServerConfiguration.constantTimeEquals("abc", "abd"))
        #expect(!ACPServerConfiguration.constantTimeEquals("abc", "abcd"))
        #expect(!ACPServerConfiguration.constantTimeEquals("", "a"))
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
struct ACPServerTokenTests {
    private let configuration = ACPServerConfiguration(port: 0, bearerToken: "s3cret")

    @Test
    func aRequestNeedsTheToken() async throws {
        try await withACPServer(configuration: configuration) { port in
            let without = try await RawHTTPConnection(port: port).request("POST", host: "devbox.lan:\(port)", body: initializeBody)
            #expect(statusLine(without).hasPrefix("HTTP/1.1 401"))
            #expect(header("WWW-Authenticate", in: without) == "Bearer")

            let wrong = try await RawHTTPConnection(port: port).request(
                "POST", host: "devbox.lan:\(port)", headers: ["Authorization": "Bearer guess"], body: initializeBody
            )
            #expect(statusLine(wrong).hasPrefix("HTTP/1.1 401"))

            let with = try await RawHTTPConnection(port: port).request(
                "POST", host: "devbox.lan:\(port)", headers: ["Authorization": "Bearer s3cret"], body: initializeBody
            )
            #expect(statusLine(with) == "HTTP/1.1 200 OK")
        }
    }

    @Test
    func aWebSocketNeedsTheToken() async throws {
        try await withACPServer(configuration: configuration) { port in
            // Hummingbird answers every refused handshake with 400.
            let without = try await RawHTTPConnection(port: port).request("GET", host: "devbox.lan:\(port)", headers: webSocketUpgrade)
            #expect(statusLine(without).hasPrefix("HTTP/1.1 400"))

            var withToken = webSocketUpgrade
            withToken["Authorization"] = "Bearer s3cret"
            let with = try await RawHTTPConnection(port: port).request("GET", host: "devbox.lan:\(port)", headers: withToken)
            #expect(statusLine(with).hasPrefix("HTTP/1.1 101"))
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPRemoteBridgeTests {
    private let configuration = ACPServerConfiguration(port: 0, bearerToken: "s3cret")

    @Test
    func addressesBecomeWebSocketURLs() {
        #expect(ACPRemoteBridge(address: "http://devbox:7878", token: nil)?.url == "ws://devbox:7878/acp")
        #expect(ACPRemoteBridge(address: "https://devbox.example/", token: nil)?.url == "wss://devbox.example/acp")
        #expect(ACPRemoteBridge(address: "wss://devbox.example/nawa/acp", token: nil)?.url == "wss://devbox.example/nawa/acp")
        #expect(ACPRemoteBridge(address: "ftp://devbox", token: nil) == nil)
        #expect(ACPRemoteBridge(address: "devbox:7878", token: nil) == nil)
    }

    @Test
    func linesTravelBothWays() async throws {
        try await withACPServer(configuration: configuration) { port in
            let bridge = try #require(ACPRemoteBridge(address: "http://127.0.0.1:\(port)", token: "s3cret"))
            let (input, typing) = AsyncThrowingStream<String, any Error>.makeStream()
            let (output, printing) = AsyncStream<String>.makeStream()
            let running = Task { try await bridge.run(input: input) { printing.yield($0) } }

            typing.yield(initializeBody)
            var lines = output.makeAsyncIterator()
            let reply = try #require(await lines.next())
            #expect(reply.contains(#""protocolVersion":1"#))
            #expect(reply.contains(#""id":0"#))

            typing.finish()
            try await running.value
        }
    }

    /// A script writes its requests and closes stdin at once: the bridge
    /// still waits for their answers before it closes.
    @Test
    func answersArriveAfterInputEnds() async throws {
        try await withACPServer(configuration: configuration) { port in
            let bridge = try #require(ACPRemoteBridge(address: "http://127.0.0.1:\(port)", token: "s3cret"))
            let input = AsyncThrowingStream<String, any Error> { typing in
                typing.yield(initializeBody)
                typing.finish()
            }
            let received = Mutex<[String]>([])

            try await bridge.run(input: input) { line in received.withLock { $0.append(line) } }

            let replies = received.withLock { $0 }
            #expect(replies.count == 1)
            #expect(replies.first?.contains(#""protocolVersion":1"#) == true)
        }
    }

    /// A broken stdin ends the bridge with its error, not a quiet wait
    /// for the server to hang up.
    @Test
    func anInputFailureEndsTheBridge() async throws {
        struct ReadFailed: Error {}
        try await withACPServer(configuration: configuration) { port in
            let bridge = try #require(ACPRemoteBridge(address: "http://127.0.0.1:\(port)", token: "s3cret"))
            let input = AsyncThrowingStream<String, any Error> { typing in
                typing.finish(throwing: ReadFailed())
            }
            await #expect(throws: ACPRemoteBridgeError.failed(bridge.url, "\(ReadFailed())")) {
                try await bridge.run(input: input) { _ in }
            }
        }
    }

    @Test
    func aWrongTokenIsRefused() async throws {
        try await withACPServer(configuration: configuration) { port in
            let bridge = try #require(ACPRemoteBridge(address: "ws://127.0.0.1:\(port)/acp", token: "guess"))
            let (input, typing) = AsyncThrowingStream<String, any Error>.makeStream()
            defer { typing.finish() }
            await #expect(throws: ACPRemoteBridgeError.refused(bridge.url)) {
                try await bridge.run(input: input) { _ in }
            }
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
