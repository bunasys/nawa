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

    /// A session whose requests to `host` get `replies`.
    static func session(host: String, replies: [Reply]) -> URLSession {
        self.replies.withLock { $0[host] = replies }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func bodies(host: String) -> [String] { bodies.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.bodies.withLock { $0[host, default: []].append(Self.body(of: request)) }
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
        let listener = socket(AF_INET, SOCK_STREAM, 0)
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

    func close() {
        shutdown(listener, SHUT_RDWR)
        Foundation.close(listener)
        accepted.withLock { if $0 >= 0 { Foundation.close($0) } }
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
