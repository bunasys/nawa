import AgentCore
@testable import AgentGateway
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fallback providers: a request the active provider can't serve moves on
/// to the next one. Each test uses its own hosts, since the stub's replies
/// are shared static state keyed by host.
struct FailoverTests {
    private func reply(_ text: String, model: String) -> StubURLProtocol.Reply {
        .init(pieces: [#"{"model":"\#(model)","choices":[{"message":{"content":"\#(text)"},"finish_reason":"stop"}]}"#])
    }

    private func gateway(primary: String, fallback: String, session: URLSession) -> Gateway {
        Gateway(
            providers: [
                ProviderConfig(name: "primary", baseURL: URL(string: "https://\(primary)/v1")!, apiKey: "k1", model: "primary-model"),
                ProviderConfig(name: "fallback", baseURL: URL(string: "https://\(fallback)/v1")!, apiKey: "k2", model: "fallback-model"),
            ],
            activeProviderName: "primary",
            fallbackProviderNames: ["fallback"],
            session: session
        )
    }

    private let hello = [Message(role: .user, text: "hi")]

    @Test
    func aRateLimitedProviderHandsTheRequestToTheFallbackWithItsOwnModel() async throws {
        let (primary, fallback) = ("limited.primary.test", "limited.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(status: 429, pieces: [#"{"error":{"message":"rate limited"}}"#])])
        let session = StubURLProtocol.session(host: fallback, replies: [reply("from fallback", model: "fallback-model")])

        let response = try await gateway(primary: primary, fallback: fallback, session: session)
            .complete(ModelRequest(model: "primary-model", messages: hello))

        #expect(response.message.text == "from fallback")
        #expect(response.providerName == "fallback")
        let sentToFallback = StubURLProtocol.bodies(host: fallback)
        #expect(sentToFallback.count == 1)
        #expect(sentToFallback[0].contains(#""model":"fallback-model""#))
    }

    @Test
    func aFailedProviderIsSkippedWhileItCoolsDown() async throws {
        let (primary, fallback) = ("cooling.primary.test", "cooling.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(status: 503, pieces: ["down"])])
        let session = StubURLProtocol.session(host: fallback, replies: [reply("one", model: "f"), reply("two", model: "f")])
        let gateway = gateway(primary: primary, fallback: fallback, session: session)

        _ = try await gateway.complete(ModelRequest(model: "primary-model", messages: hello))
        let second = try await gateway.complete(ModelRequest(model: "primary-model", messages: hello))

        #expect(second.message.text == "two")
        #expect(StubURLProtocol.bodies(host: primary).count == 1)
        // First in line now, but still not the provider the model id was meant for.
        let sentToFallback = StubURLProtocol.bodies(host: fallback)
        #expect(sentToFallback.allSatisfy { $0.contains(#""model":"fallback-model""#) })
    }

    @Test
    func aMalformedRequestFailsWithoutTryingTheFallback() async throws {
        let (primary, fallback) = ("malformed.primary.test", "malformed.fallback.test")
        let session = StubURLProtocol.session(host: primary, replies: [.init(status: 400, pieces: ["bad request"])])

        await #expect(throws: GatewayError.self) {
            try await gateway(primary: primary, fallback: fallback, session: session).complete(ModelRequest(messages: hello))
        }
        #expect(StubURLProtocol.bodies(host: fallback).isEmpty)
    }

    @Test
    func whenEveryProviderFailsTheErrorNamesEachOne() async throws {
        let (primary, fallback) = ("all.primary.test", "all.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(status: 429, pieces: ["slow down"])])
        let session = StubURLProtocol.session(host: fallback, replies: [.init(status: 401, pieces: ["bad key"])])

        do {
            _ = try await gateway(primary: primary, fallback: fallback, session: session).complete(ModelRequest(messages: hello))
            Issue.record("expected an error")
        } catch GatewayError.providersFailed(let failures) {
            #expect(failures.count == 2)
            #expect(failures[0].hasPrefix("primary: ") && failures[0].contains("429"))
            #expect(failures[1].hasPrefix("fallback: ") && failures[1].contains("401"))
        }
    }

    @Test
    func aStreamFailsOverWhenTheProviderFailsBeforeAnswering() async throws {
        let (primary, fallback) = ("stream.primary.test", "stream.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(status: 529, pieces: ["overloaded"])])
        let session = StubURLProtocol.session(host: fallback, replies: [
            .init(pieces: [sse([#"{"model":"f","choices":[{"delta":{"content":"streamed"},"finish_reason":"stop"}]}"#, "[DONE]"])]),
        ])

        let (deltas, response) = try await collect(
            gateway(primary: primary, fallback: fallback, session: session).stream(ModelRequest(messages: hello))
        )

        #expect(deltas == ["text:streamed"])
        #expect(response?.message.text == "streamed")
    }

    /// Real sockets from here on: the stub answers at once, and these need a
    /// reply that is cut off or never ends. Port 1 refuses connections.
    private func socketGateway(primary: String, fallback: String) -> Gateway {
        Gateway(
            providers: [
                ProviderConfig(name: "primary", baseURL: URL(string: "\(primary)/v1")!, model: "m"),
                ProviderConfig(name: "fallback", baseURL: URL(string: "\(fallback)/v1")!, model: "m"),
            ],
            activeProviderName: "primary",
            fallbackProviderNames: ["fallback"]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamThatBreaksAfterItsFirstChunkDoesNotFailOver() async throws {
        let server = try HangingHTTPServer(firstBytes: sse([#"{"choices":[{"delta":{"content":"Hel"}}]}"#]))
        let gateway = socketGateway(primary: "http://127.0.0.1:\(server.port)", fallback: "http://127.0.0.1:1")

        var deltas: [String] = []
        do {
            for try await chunk in gateway.stream(ModelRequest(messages: hello)) {
                guard case .textDelta(let text) = chunk else { continue }
                deltas.append(text)
                server.close()
            }
            Issue.record("expected the cut-off stream to fail")
        } catch GatewayError.providersFailed(let failures) {
            Issue.record("failed over after the first chunk: \(failures)")
        } catch {
            // The primary's own error: nothing went to the fallback.
        }
        #expect(deltas == ["Hel"])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringAFailoverIsReportedAsACancellation() async throws {
        // Not empty: an empty chunk would end the chunked body.
        let server = try HangingHTTPServer(firstBytes: "{")
        defer { server.close() }
        let gateway = socketGateway(primary: "http://127.0.0.1:1", fallback: "http://127.0.0.1:\(server.port)")

        let call = Task { try await gateway.complete(ModelRequest(messages: hello)) }
        while !server.hasAccepted { try await Task.sleep(for: .milliseconds(10)) }
        call.cancel()

        do {
            _ = try await call.value
            Issue.record("expected the cancelled call to fail")
        } catch GatewayError.providersFailed(let failures) {
            Issue.record("a cancellation came back as a provider failure: \(failures)")
        } catch {
            #expect(!GatewayFailover.isProviderUnavailable(error), "\(error)")
        }
        // The user stopped it; the fallback didn't fail.
        #expect(!gateway.failover.isCoolingDown("fallback"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aFallbackStreamCutOffMidReplyKeepsItsOwnError() async throws {
        let server = try HangingHTTPServer(firstBytes: sse([#"{"choices":[{"delta":{"content":"Hel"}}]}"#]))
        let gateway = socketGateway(primary: "http://127.0.0.1:1", fallback: "http://127.0.0.1:\(server.port)")

        do {
            for try await chunk in gateway.stream(ModelRequest(messages: hello)) {
                if case .textDelta = chunk { server.close() }
            }
            Issue.record("expected the cut-off stream to fail")
        } catch GatewayError.providersFailed(let failures) {
            Issue.record("the fallback answered, yet the error says every provider failed: \(failures)")
        } catch {
            // The fallback's own error.
        }
    }

    @Test
    func aMissingModelFailsOverWithoutTakingTheProviderOut() async throws {
        let (primary, fallback) = ("missing-model.primary.test", "missing-model.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [
            .init(status: 404, pieces: [#"{"error":{"message":"model not found"}}"#]),
            reply("primary is fine", model: "primary-model"),
        ])
        let session = StubURLProtocol.session(host: fallback, replies: [reply("from fallback", model: "f")])
        let gateway = gateway(primary: primary, fallback: fallback, session: session)

        let typo = try await gateway.complete(ModelRequest(model: "primary-modle", messages: hello))
        let next = try await gateway.complete(ModelRequest(messages: hello))

        #expect(typo.providerName == "fallback")
        #expect(next.providerName == "primary" && next.message.text == "primary is fine")
    }

    @Test
    func aRequestThatMayNotFailOverStaysOnItsProvider() async throws {
        let (primary, fallback) = ("pinned.primary.test", "pinned.fallback.test")
        let session = StubURLProtocol.session(host: primary, replies: [.init(status: 429, pieces: ["slow down"])])
        let gateway = gateway(primary: primary, fallback: fallback, session: session)

        await #expect(throws: GatewayError.self) {
            try await gateway.complete(ModelRequest(messages: hello, mayFailOver: false))
        }
        #expect(StubURLProtocol.bodies(host: fallback).isEmpty)
        // It stayed put, so it doesn't reroute other requests either.
        #expect(!gateway.failover.isCoolingDown("primary"))
    }

    @Test
    func theLastProviderCoolsDownToo() async throws {
        let (primary, fallback) = ("last.primary.test", "last.fallback.test")
        _ = StubURLProtocol.session(host: primary, replies: [.init(status: 429, pieces: ["a"])])
        let session = StubURLProtocol.session(host: fallback, replies: [.init(status: 429, pieces: ["b"])])
        let gateway = gateway(primary: primary, fallback: fallback, session: session)

        _ = try? await gateway.complete(ModelRequest(messages: hello))

        #expect(gateway.failover.isCoolingDown("primary"))
        #expect(gateway.failover.isCoolingDown("fallback"))
    }

    @Test
    func aRequestThatNamesAProviderNeverFailsOver() async throws {
        let (primary, fallback) = ("named.primary.test", "named.fallback.test")
        let session = StubURLProtocol.session(host: primary, replies: [.init(status: 503, pieces: ["down"])])

        await #expect(throws: GatewayError.self) {
            try await gateway(primary: primary, fallback: fallback, session: session)
                .complete(ModelRequest(providerName: "primary", messages: hello))
        }
        #expect(StubURLProtocol.bodies(host: fallback).isEmpty)
    }

    @Test
    func whichErrorsMeanTheProviderIsUnavailable() {
        let unavailable: [any Error] = [
            GatewayError.httpError(statusCode: 429, body: ""),
            GatewayError.httpError(statusCode: 529, body: ""),
            GatewayError.httpError(statusCode: 401, body: ""),
            GatewayError.httpError(statusCode: 400, body: #"{"error":{"message":"Your credit balance is too low"}}"#),
            GatewayError.network("reset"),
            URLError(.timedOut),
        ]
        let final: [any Error] = [
            GatewayError.httpError(statusCode: 400, body: "messages: field required"),
            GatewayError.httpError(statusCode: 413, body: ""),
            GatewayError.httpError(statusCode: 409, body: ""),
            CancellationError(),
            URLError(.cancelled),
        ]
        for error in unavailable { #expect(GatewayFailover.isProviderUnavailable(error), "\(error)") }
        for error in final { #expect(!GatewayFailover.isProviderUnavailable(error), "\(error)") }
    }

    @Test
    func aCooldownEnds() {
        let failover = GatewayFailover()
        let failedAt = Date(timeIntervalSince1970: 1000)
        failover.markFailed("p", now: failedAt)
        #expect(failover.isCoolingDown("p", now: failedAt.addingTimeInterval(GatewayFailover.cooldown - 1)))
        #expect(!failover.isCoolingDown("p", now: failedAt.addingTimeInterval(GatewayFailover.cooldown)))
        #expect(!failover.isCoolingDown("other", now: failedAt))
    }

    @Test
    func aConfigFileNamesItsFallbacks() throws {
        let json = #"{"activeProvider":"a","providers":[{"name":"a","baseURL":"https://a.test"},{"name":"b","baseURL":"https://b.test"}],"fallbackProviders":["b"]}"#
        let config = try JSONDecoder().decode(GatewayConfig.self, from: Data(json.utf8))
        #expect(config.makeGateway().fallbackProviderNames == ["b"])
        let older = try JSONDecoder().decode(GatewayConfig.self, from: Data(#"{"providers":[]}"#.utf8))
        #expect(older.makeGateway().fallbackProviderNames.isEmpty)
    }
}
