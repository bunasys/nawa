import AgentCore
@testable import AgentGateway
import Foundation
import Synchronization
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers requests from a script, per host, so streaming can be tested
/// without a network: each reply is a status and body pieces.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var pieces: [String]
    }

    /// Host → replies, served in order; the bodies received, per host.
    private static let replies = Mutex<[String: [Reply]]>([:])
    private static let bodies = Mutex<[String: [String]]>([:])
    private static let timeouts = Mutex<[String: [TimeInterval]]>([:])
    private static let sessionIDs = Mutex<[String: [String?]]>([:])

    /// A session whose requests to `host` get `replies`.
    static func session(host: String, replies: [Reply]) -> URLSession {
        self.replies.withLock { $0[host] = replies }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func bodies(host: String) -> [String] { bodies.withLock { $0[host] ?? [] } }
    static func timeouts(host: String) -> [TimeInterval] { timeouts.withLock { $0[host] ?? [] } }
    static func sessionIDs(host: String) -> [String?] { sessionIDs.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.bodies.withLock { $0[host, default: []].append(Self.body(of: request)) }
        Self.timeouts.withLock { $0[host, default: []].append(request.timeoutInterval) }
        Self.sessionIDs.withLock { $0[host, default: []].append(request.value(forHTTPHeaderField: "x-session-id")) }
        let reply = Self.replies.withLock { replies -> Reply? in
            guard var queue = replies[host], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            replies[host] = queue
            return next
        } ?? Reply(status: 500, pieces: ["no reply scripted"])
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in reply.pieces { client?.urlProtocol(self, didLoad: Data(piece.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// An HTTP server on 127.0.0.1 that answers one request with a streamed
/// 200, writes `firstBytes`, and then keeps the connection open.
final class HangingHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let accepted = Mutex<Int32>(-1)

    init(firstBytes: String) throws {
        #if canImport(Glibc)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        self.listener = listener
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                guard bind(listener, raw, length) == 0, listen(listener, 1) == 0,
                      getsockname(listener, raw, &length) == 0
                else { throw POSIXError(.EADDRINUSE) }
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            accepted.withLock { $0 = connection }
            var buffer = [UInt8](repeating: 0, count: 65536)
            _ = read(connection, &buffer, buffer.count)  // the request; its contents don't matter
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            let chunk = String(firstBytes.utf8.count, radix: 16) + "\r\n" + firstBytes + "\r\n"
            _ = (head + chunk).withCString { write(connection, $0, strlen($0)) }
        }.start()
    }

    /// Whether a client has connected yet.
    var hasAccepted: Bool { accepted.withLock { $0 >= 0 } }

    /// Cut the connection with a reset rather than an orderly close: after
    /// a plain close, macOS now and then treated the unfinished chunked body
    /// as a normal end, and the cut-off tests failed on CI.
    func close() {
        shutdown(listener, Int32(SHUT_RDWR))
        Foundation.close(listener)
        accepted.withLock { connection in
            guard connection >= 0 else { return }
            var resetOnClose = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_LINGER, &resetOnClose, socklen_t(MemoryLayout<linger>.size))
            Foundation.close(connection)
        }
    }
}

/// `data:` lines for an SSE body.
func sse(_ payloads: [String]) -> String {
    payloads.map { "data: \($0)\n\n" }.joined()
}

func collect(_ stream: AsyncThrowingStream<StreamChunk, any Error>) async throws -> (deltas: [String], response: ModelResponse?) {
    var deltas: [String] = []
    var response: ModelResponse?
    for try await chunk in stream {
        if case .finished(let reply) = chunk { response = reply } else { deltas.append(describe(chunk)) }
    }
    return (deltas, response)
}

func describe(_ chunk: StreamChunk) -> String {
    switch chunk {
    case .thinkingDelta(let text): "think:\(text)"
    case .textDelta(let text): "text:\(text)"
    case .toolCallStart(let call): "call:\(call.id):\(call.name)"
    case .toolCallArguments(let id, let json): "args:\(id):\(json)"
    case .finished: "finished"
    }
}

struct ServerSentEventsTests {
    @Test
    func dataLinesAreHandedOverOneByOneWhateverTheLineEndings() async throws {
        let body = "event: x\r\ndata: {\"a\":1}\r\n\r\n: comment\ndata:{\"b\":2}\n\ndata: [DONE]"
        var payloads: [String] = []
        try await ServerSentEvents.forEachData(in: AsyncStream { c in
            for byte in body.utf8 { c.yield(byte) }
            c.finish()
        }) { payloads.append($0) }
        #expect(payloads == ["{\"a\":1}", "{\"b\":2}", "[DONE]"])
    }

    @Test
    func anEndlessLineFailsTheStream() async {
        let bytes = AsyncStream<UInt8> { c in
            for _ in 0...ServerSentEvents.maxLineBytes { c.yield(UInt8(ascii: "x")) }
            c.finish()
        }
        await #expect(throws: GatewayError.self) {
            try await ServerSentEvents.forEachData(in: bytes) { _ in }
        }
    }
}

struct OpenAIStreamingTests {
    @Test
    func reasoningTextAndToolCallsStreamAndAddUp() throws {
        var assembler = OpenAIStreamAssembler()
        var deltas: [StreamChunk] = []
        for payload in [
            #"{"choices":[{"delta":{"reasoning_content":"Let me "}}]}"#,
            #"{"choices":[{"delta":{"reasoning":"think."}}]}"#,
            #"{"choices":[{"delta":{"content":"Running it."}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"shell","arguments":"{\"comm"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":60}}}"#,
            "[DONE]",
        ] {
            deltas += try assembler.consume(payload)
        }
        #expect(deltas.count == 6)
        guard case .thinkingDelta("Let me ") = deltas[0], case .thinkingDelta("think.") = deltas[1],
              case .textDelta("Running it.") = deltas[2], case .toolCallStart(let call) = deltas[3]
        else { Issue.record("unexpected deltas \(deltas)"); return }
        #expect(call.id == "c1" && call.name == "shell")

        let response = assembler.response()
        #expect(response.message.text == "Running it.")
        #expect(response.message.toolCalls == [ToolCall(id: "c1", name: "shell", arguments: .object(["command": .string("ls")]))])
        #expect(response.finishReason == .toolUse)
        #expect(response.usage == Usage(inputTokens: 40, outputTokens: 20, cacheReadTokens: 60))
    }

    @Test
    func anErrorChunkFailsTheStream() {
        var assembler = OpenAIStreamAssembler()
        #expect(throws: GatewayError.self) {
            _ = try assembler.consume(#"{"error":{"message":"overloaded"}}"#)
        }
    }

    @Test
    func theRequestAsksForUsageAndUsesWireNames() throws {
        let body = OpenAIRequest(model: "m", messages: [], stream: true, maxTokens: 10, streamOptions: ["include_usage": true])
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        #expect(json.contains(#""stream_options":{"include_usage":true}"#))
        #expect(json.contains(#""max_tokens":10"#))
    }

    @Test(.timeLimit(.minutes(1)))
    func gatewayYieldsChunksBeforeTheReplyEnds() async throws {
        // A real socket: URLSession only hands bytes over as they arrive from the network.
        let server = try HangingHTTPServer(firstBytes: sse([#"{"choices":[{"delta":{"content":"Hel"}}]}"#]))
        defer { server.close() }
        let gateway = Gateway(providers: [ProviderConfig(name: "p", baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!, model: "m")])
        // The reply never ends; the first delta must still arrive.
        for try await chunk in gateway.stream(ModelRequest(messages: [Message(role: .user, text: "hi")])) {
            guard case .textDelta(let text) = chunk else { continue }
            #expect(text == "Hel")
            break
        }
    }

    @Test
    func gatewayPassesErrorsOn() async throws {
        let host = "fails.test"
        let session = StubURLProtocol.session(host: host, replies: [.init(status: 500, pieces: ["boom"])])
        let gateway = Gateway(providers: [ProviderConfig(name: "p", baseURL: URL(string: "https://\(host)/v1")!, model: "m")], session: session)
        await #expect(throws: GatewayError.self) {
            _ = try await collect(gateway.stream(ModelRequest(messages: [Message(role: .user, text: "hi")])))
        }
    }

    @Test
    func aServerThatRejectsStreamOptionsIsAskedAgainWithout() async throws {
        let host = "no-stream-options.test"
        let ok = StubURLProtocol.Reply(pieces: [sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]"])])
        let session = StubURLProtocol.session(host: host, replies: [
            .init(status: 400, pieces: [#"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#]),
            ok, ok,
        ])
        let client = OpenAICompatibleClient(providerName: "p", baseURL: URL(string: "https://\(host)/v1")!, session: session)
        let request = ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")])

        let first = try await collect(client.stream(request))
        #expect(first.response?.message.text == "ok")
        // Remembered: the next request goes without it straight away.
        let second = try await collect(client.stream(request))
        #expect(second.deltas == ["text:ok"])
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 3)
        #expect(bodies[0].contains("stream_options"))
        #expect(!bodies[1].contains("stream_options") && !bodies[2].contains("stream_options"))
    }

    /// A slow reply (a long context, or a proxy that waits for the whole
    /// reply) must not hit URLSession's 60-second default.
    @Test
    func chatRequestsWaitMinutesNotSeconds() async throws {
        let host = "slow-chat.test"
        let session = StubURLProtocol.session(host: host, replies: [
            .init(pieces: [#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#]),
            .init(pieces: [sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]"])]),
        ])
        let client = OpenAICompatibleClient(providerName: "p", baseURL: URL(string: "https://\(host)/v1")!, session: session)
        let request = ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")])

        _ = try await client.complete(request)
        _ = try await collect(client.stream(request))

        #expect(StubURLProtocol.timeouts(host: host) == [600, 600])
    }

    /// A caller that knows its replies are quick sets a shorter wait per
    /// provider, so a hanging provider fails over in minutes, not ten.
    @Test
    func aProvidersRequestTimeoutReachesItsRequests() async throws {
        let (openAIHost, anthropicHost) = ("quick-openai.test", "quick-anthropic.test")
        _ = StubURLProtocol.session(host: openAIHost, replies: [
            .init(pieces: [#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#]),
        ])
        let session = StubURLProtocol.session(host: anthropicHost, replies: [
            .init(pieces: [#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#]),
        ])
        let gateway = Gateway(
            providers: [
                ProviderConfig(name: "openai", baseURL: URL(string: "https://\(openAIHost)/v1")!, apiKey: "k", model: "m", requestTimeout: 120),
                ProviderConfig(name: "claude", api: .anthropic, baseURL: URL(string: "https://\(anthropicHost)")!, apiKey: "k", model: "m", requestTimeout: 90),
            ],
            activeProviderName: "openai",
            session: session
        )
        let request = ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")])

        _ = try await gateway.client(for: "openai").complete(request)
        _ = try await gateway.client(for: "claude").complete(request)

        #expect(StubURLProtocol.timeouts(host: openAIHost) == [120])
        #expect(StubURLProtocol.timeouts(host: anthropicHost) == [90])
    }

    /// Providers cache the longest identical prefix of a request, so the
    /// same request must be the same bytes every turn, though its tool
    /// schemas are dictionaries rebuilt each time.
    @Test
    func theSameRequestIsTheSameBytesAndNamesItsSession() async throws {
        let host = "cacheable.test"
        let ok = StubURLProtocol.Reply(pieces: [#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#])
        let session = StubURLProtocol.session(host: host, replies: Array(repeating: ok, count: 8))
        let client = OpenAICompatibleClient(providerName: "p", baseURL: URL(string: "https://\(host)/v1")!, session: session)
        func freshTool() -> ToolDefinition {
            let properties = Dictionary(uniqueKeysWithValues: (1...12).map { ("field\($0)", JSON.object(["type": .string("string")])) })
            return ToolDefinition(name: "t", description: "", parameters: .object(["type": .string("object"), "properties": .object(properties)]))
        }

        for _ in 0..<8 {
            let request = ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")], tools: [freshTool()], sessionID: "s1")
            _ = try await client.complete(request)
        }

        #expect(Set(StubURLProtocol.bodies(host: host)).count == 1)
        // Sorted, not insertion order (field1, field2, …): deterministic even
        // where equal dictionaries happen to iterate alike.
        let sortedProperties = (1...12).map { #""field\#($0)":{"type":"string"}"# }.sorted().joined(separator: ",")
        #expect(StubURLProtocol.bodies(host: host).allSatisfy { $0.contains(sortedProperties) })
        #expect(StubURLProtocol.sessionIDs(host: host) == Array(repeating: "s1", count: 8))
    }

    /// The request's own timeout must win over the session's, on Linux too:
    /// there, a timeout passed to `URLRequest`'s init is ignored, and a
    /// review on Linux was cut off this way after 60 s.
    @Test(.timeLimit(.minutes(1)))
    func aSessionsShortTimeoutDoesNotCutAChatReply() async throws {
        final class Outcome: Sendable {
            let text = Mutex<String?>(nil)
        }
        // Not empty: an empty chunk would end the chunked body.
        let server = try HangingHTTPServer(firstBytes: "{")
        defer { server.close() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let client = OpenAICompatibleClient(
            providerName: "p", baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            session: URLSession(configuration: configuration)
        )
        let outcome = Outcome()
        let call = Task {
            do {
                _ = try await client.complete(ModelRequest(model: "m", messages: [Message(role: .user, text: "hi")]))
                outcome.text.withLock { $0 = "answered" }
            } catch {
                outcome.text.withLock { $0 = "\(error)" }
            }
        }

        try await Task.sleep(for: .seconds(3))

        #expect(outcome.text.withLock { $0 } == nil, "still waiting after 3 s, past the session's 1 s")
        call.cancel()
    }
}

/// `ResponseByteStream` is what streams on Linux; it is tested here on
/// every platform.
struct ResponseByteStreamTests {
    @Test
    func theBodyArrivesWholeAndInOrder() async throws {
        let host = "byte-stream.test"
        let session = StubURLProtocol.session(host: host, replies: [.init(pieces: ["data: one\n", "", "data: two\n"])])
        let (bytes, response) = try await ResponseByteStream.open(
            URLRequest(url: URL(string: "https://\(host)/x")!), on: session
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await collectText(bytes) == "data: one\ndata: two\n")
    }

    @Test
    func anErrorStatusStillComesWithItsBody() async throws {
        let host = "byte-stream-error.test"
        let session = StubURLProtocol.session(host: host, replies: [.init(status: 503, pieces: ["overloaded"])])
        let (bytes, response) = try await ResponseByteStream.open(
            URLRequest(url: URL(string: "https://\(host)/x")!), on: session
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        #expect(try await collectText(bytes) == "overloaded")
    }

    @Test
    func aFailedConnectionIsAnError() async throws {
        // Port 1 on loopback: nothing listens there.
        await #expect(throws: (any Error).self) {
            _ = try await ResponseByteStream.open(
                URLRequest(url: URL(string: "http://127.0.0.1:1/x")!), on: URLSession(configuration: .ephemeral)
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bytesArriveBeforeTheResponseEndsAndStoppingEndsIt() async throws {
        let server = try HangingHTTPServer(firstBytes: "data: first\n")
        defer { server.close() }
        let (bytes, _) = try await ResponseByteStream.open(
            URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/x")!), on: URLSession(configuration: .ephemeral)
        )
        // The response never ends; the first line must still come through,
        // and leaving the loop must not hang.
        var line: [UInt8] = []
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
        }
        #expect(String(decoding: line, as: UTF8.self) == "data: first")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheReaderEndsAHangingResponse() async throws {
        let server = try HangingHTTPServer(firstBytes: "data: first\n")
        defer { server.close() }
        let reader = Task {
            let (bytes, _) = try await ResponseByteStream.open(
                URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/x")!), on: URLSession(configuration: .ephemeral)
            )
            var count = 0
            for try await _ in bytes { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        // Either an error or an early end is fine; hanging is not.
        _ = try? await reader.value
    }

    /// Releasing a session after HTTPS aborts the process on Linux
    /// (swift-corelibs-foundation#5203), so streams reuse one per session.
    @Test
    func requestsAskedOnOneSessionShareOneStreamingSession() {
        let first = URLSession(configuration: .ephemeral)
        let second = URLSession(configuration: .ephemeral)
        #expect(StreamingSession.for(first) === StreamingSession.for(first))
        #expect(StreamingSession.for(first) !== StreamingSession.for(second))
    }

    @Test
    func aReleasedOwnersStreamingSessionServesTheNextOwnerWithTheSameSettings() {
        // Unusual timeouts keep other tests, which run in parallel, from
        // taking over the released entry first.
        func session(timeout: TimeInterval) -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            return URLSession(configuration: configuration)
        }
        // A released URLSession is freed at once (checked on macOS and Linux),
        // which clears the streaming session's weak reference to it.
        var first: URLSession? = session(timeout: 123.25)
        let streaming = StreamingSession.for(first!)
        first = nil

        #expect(StreamingSession.for(session(timeout: 123.25)) === streaming)
        #expect(StreamingSession.for(session(timeout: 456.75)) !== streaming)
    }

    @Test
    func sharedStreamingSessionsKeepNoCookiesCredentialsOrCache() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 321.5
        let stateless = StreamingSession.stateless(configuration)
        #expect(stateless.httpCookieStorage == nil)
        #expect(stateless.httpShouldSetCookies == false)
        #expect(stateless.urlCredentialStorage == nil)
        #expect(stateless.urlCache == nil)
        #expect(stateless.timeoutIntervalForRequest == 321.5)
        // The caller's configuration is left as it was.
        #expect(configuration.httpCookieStorage != nil)
    }

    @Test
    func differentProxiesDoNotShareAStreamingSession() {
        let direct = URLSessionConfiguration.ephemeral
        let proxied = URLSessionConfiguration.ephemeral
        proxied.connectionProxyDictionary = ["HTTPSProxy": "proxy.example", "HTTPSPort": 8080]
        #expect(!StreamingSession.sameSettings(direct, proxied))
        #expect(StreamingSession.sameSettings(direct, URLSessionConfiguration.ephemeral))
    }

    @Test(.timeLimit(.minutes(1)))
    func aReaderCancelledBeforeTheRequestStartsEndsAtOnce() async throws {
        let server = try HangingHTTPServer(firstBytes: "data: first\n")
        defer { server.close() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 789.5
        let owner = URLSession(configuration: configuration)

        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ResponseByteStream.open(
                URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/x")!), on: owner
            )
        }
        await #expect(throws: (any Error).self) { _ = try await reader.value }
        #expect(StreamingSession.for(owner).pendingRequests == 0)
    }

    @Test
    func concurrentStreamsOnOneSessionEachGetTheirOwnBody() async throws {
        let session = StubURLProtocol.session(host: "shared-a.test", replies: [.init(pieces: ["a1\n", "a2\n"])])
        _ = StubURLProtocol.session(host: "shared-b.test", replies: [.init(pieces: ["b1\n", "b2\n"])])
        async let a = ResponseByteStream.open(URLRequest(url: URL(string: "https://shared-a.test/x")!), on: session)
        async let b = ResponseByteStream.open(URLRequest(url: URL(string: "https://shared-b.test/x")!), on: session)
        let (bytesA, _) = try await a
        let (bytesB, _) = try await b
        #expect(try await collectText(bytesA) == "a1\na2\n")
        #expect(try await collectText(bytesB) == "b1\nb2\n")
    }
}

@Suite
struct AnthropicStreamingTests {
    /// What the Messages API streams for a reply with thinking, text and a
    /// tool call (taken from the documented event sequence).
    static let events = [
        #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":12,"cache_read_input_tokens":100,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"check."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"ping"}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Check"}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ing."}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"echo","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"text\":"}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"hi\"}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        #"{"type":"message_stop"}"#,
    ]

    static func assemble(_ events: [String]) throws -> (chunks: [StreamChunk], response: ModelResponse) {
        var assembler = AnthropicStreamAssembler(providerName: "test")
        var chunks: [StreamChunk] = []
        for event in events { chunks += try assembler.consume(event) }
        return (chunks, try assembler.response())
    }

    @Test
    func deltasArriveAsChunks() throws {
        let (chunks, _) = try Self.assemble(Self.events)
        #expect(chunks.map(describe) == [
            "think:Let me ", "think:check.", "text:Check", "text:ing.",
            "call:t1:echo", #"args:t1:{"text":"#, #"args:t1:"hi"}"#,
        ])
    }

    @Test
    func theStreamedReplyMatchesTheNonStreamedOne() throws {
        let (_, streamed) = try Self.assemble(Self.events)
        let whole = try AnthropicClient.modelResponse(from: .object([
            "content": .array([
                .object(["type": .string("thinking"), "thinking": .string("Let me check."), "signature": .string("sig==")]),
                .object(["type": .string("text"), "text": .string("Checking.")]),
                .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("echo"),
                         "input": .object(["text": .string("hi")])]),
            ]),
            "stop_reason": .string("tool_use"),
            "usage": .object(["input_tokens": .int(12), "cache_read_input_tokens": .int(100), "output_tokens": .int(42)]),
        ]), providerName: "test")

        #expect(streamed.message.content == whole.message.content)
        #expect(streamed.finishReason == .toolUse)
        #expect(streamed.usage == whole.usage)
        #expect(streamed.usage.outputTokens == 42)
    }

    @Test
    func redactedThinkingIsKeptAsItStarted() throws {
        let block = #"{"type":"redacted_thinking","data":"opaque-bytes"}"#
        let (_, response) = try Self.assemble([
            #"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":\#(block)}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_stop"}"#,
        ])
        let payload = try JSONDecoder().decode(JSON.self, from: Data(block.utf8))
        #expect(response.message.content == [.opaque(provider: "anthropic", payload: payload)])
    }

    @Test
    func anErrorEventFailsTheStream() {
        #expect(throws: GatewayError.self) {
            try Self.assemble([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        }
    }

    @Test
    func aStreamCutBeforeMessageStopFails() {
        #expect(throws: GatewayError.self) {
            try Self.assemble(Array(Self.events.dropLast()))
        }
    }

    @Test
    func theClientStreamsOverHTTP() async throws {
        let host = "anthropic-stream.test"
        let session = StubURLProtocol.session(host: host, replies: [.init(pieces: [sse(Self.events)])])
        let client = AnthropicClient(providerName: "claude", baseURL: URL(string: "https://\(host)/v1")!, apiKey: "k", session: session)
        let (deltas, response) = try await collect(client.stream(ModelRequest(model: "claude", messages: [Message(role: .user, text: "hi")])))

        #expect(deltas.first == "think:Let me ")
        #expect(response?.message.text == "Checking.")
        let body = try #require(StubURLProtocol.bodies(host: host).first)
        #expect(body.contains(#""stream":true"#))
    }
}

@Suite
struct StreamLimitTests {
    @Test
    func toolArgumentsCannotGrowWithoutBound() throws {
        var assembler = AnthropicStreamAssembler(providerName: "test")
        _ = try assembler.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"echo","input":{}}}"#)
        let piece = String(repeating: "a", count: 1 << 20)
        let event = #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(piece)"}}"#
        #expect(throws: GatewayError.self) {
            for _ in 0..<9 { _ = try assembler.consume(event) }
        }
    }
}
