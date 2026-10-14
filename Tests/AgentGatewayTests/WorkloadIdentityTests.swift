import AgentCore
@testable import AgentGateway
import Foundation
import Testing

/// A fake `/v1/oauth/token` endpoint: counts exchanges, records the last body,
/// and answers with a numbered token or an error status.
final class TokenEndpointStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var exchanges = 0
    nonisolated(unsafe) static var lastBody: JSON?
    nonisolated(unsafe) static var failWithStatus: Int?
    nonisolated(unsafe) static var expiresIn = 600

    static func reset() {
        exchanges = 0
        lastBody = nil
        failWithStatus = nil
        expiresIn = 600
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenEndpointStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.exchanges += 1
        // URLProtocol sees the body as a stream, not `httpBody`.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = try? JSONDecoder().decode(JSON.self, from: data)
        }
        let status = Self.failWithStatus ?? 200
        let body = status == 200
            ? #"{"access_token":"sk-ant-oat01-\#(Self.exchanges)","token_type":"Bearer","expires_in":\#(Self.expiresIn)}"#
            : #"{"type":"error","error":{"type":"authentication_error","message":"Authentication failed"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

// Serialized: the stub's counters are shared static state.
@Suite(.serialized)
struct WorkloadIdentityTests {
    let config = WorkloadIdentityConfig(
        federationRuleID: "fdrl_1",
        organizationID: "00000000-0000-0000-0000-000000000000",
        serviceAccountID: "svac_1",
        workspaceID: "wrkspc_1",
        identityToken: "header.payload.signature"
    )
    let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!

    func makeSource(clock: TestClock) -> WorkloadIdentityTokenSource {
        TokenEndpointStub.reset()
        return WorkloadIdentityTokenSource(
            config: config, tokenURL: tokenURL, session: TokenEndpointStub.session(), now: { clock.current }
        )
    }

    @Test
    func environmentActivatesOnlyWithAllRequiredVariables() {
        let complete = [
            "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_1",
            "ANTHROPIC_ORGANIZATION_ID": "org",
            "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_1",
            "ANTHROPIC_IDENTITY_TOKEN_FILE": "/var/run/secrets/anthropic.com/token",
        ]
        var withoutToken = complete
        withoutToken["ANTHROPIC_IDENTITY_TOKEN_FILE"] = nil

        let parsed = WorkloadIdentityConfig.fromEnvironment(complete)
        #expect(parsed?.identityTokenFile == "/var/run/secrets/anthropic.com/token")
        #expect(parsed?.workspaceID == nil)
        #expect(WorkloadIdentityConfig.fromEnvironment(withoutToken) == nil)
    }

    @Test
    func identityTokenFileIsReadAtExchangeTime() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-jwt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var fileConfig = config
        fileConfig.identityTokenFile = file.path

        try "first.jwt\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try fileConfig.readIdentityToken() == "first.jwt")
        try "rotated.jwt".write(to: file, atomically: true, encoding: .utf8)
        #expect(try fileConfig.readIdentityToken() == "rotated.jwt")
    }

    @Test
    func exchangeSendsJWTBearerGrantAndCachesToken() async throws {
        let clock = TestClock()
        let source = makeSource(clock: clock)

        let first = try await source.accessToken()
        clock.advance(by: 60)
        let second = try await source.accessToken()

        #expect(first == "sk-ant-oat01-1")
        #expect(second == first)
        #expect(TokenEndpointStub.exchanges == 1)
        let body = try #require(TokenEndpointStub.lastBody?.objectValue)
        #expect(body["grant_type"]?.stringValue == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(body["assertion"]?.stringValue == "header.payload.signature")
        #expect(body["federation_rule_id"]?.stringValue == "fdrl_1")
        #expect(body["service_account_id"]?.stringValue == "svac_1")
        #expect(body["workspace_id"]?.stringValue == "wrkspc_1")
    }

    @Test
    func refreshesInsideAdvisoryWindow() async throws {
        let clock = TestClock()
        let source = makeSource(clock: clock)

        _ = try await source.accessToken()
        clock.advance(by: 600 - 100)  // 100 s left: inside the 120 s advisory window
        let refreshed = try await source.accessToken()

        #expect(refreshed == "sk-ant-oat01-2")
    }

    @Test
    func failedAdvisoryRefreshKeepsServingCachedToken() async throws {
        let clock = TestClock()
        let source = makeSource(clock: clock)

        let original = try await source.accessToken()
        TokenEndpointStub.failWithStatus = 503
        clock.advance(by: 600 - 100)
        #expect(try await source.accessToken() == original)

        clock.advance(by: 80)  // 20 s left: past the mandatory 30 s margin
        await #expect(throws: GatewayError.self) { try await source.accessToken() }
    }

    @Test
    func rejectedExchangeExplainsWhereToLook() async {
        let source = makeSource(clock: TestClock())
        TokenEndpointStub.failWithStatus = 401

        do {
            _ = try await source.accessToken()
            Issue.record("expected the exchange to fail")
        } catch GatewayError.workloadIdentity(let message) {
            #expect(message.contains("HTTP 401"))
            #expect(message.contains("workload-identity-federation"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func concurrentCallersShareOneExchange() async throws {
        let source = makeSource(clock: TestClock())

        async let a = source.accessToken()
        async let b = source.accessToken()
        async let c = source.accessToken()
        let tokens = try await [a, b, c]

        #expect(Set(tokens).count == 1)
        #expect(TokenEndpointStub.exchanges == 1)
    }

    @Test
    func gatewayPrefersAPIKeyOverWorkloadIdentity() throws {
        let base = URL(string: "https://api.anthropic.com")!
        let withKey = ProviderConfig(name: "k", api: .anthropic, baseURL: base, apiKey: "sk-ant-api", workloadIdentity: config)
        let withoutKey = ProviderConfig(name: "w", api: .anthropic, baseURL: base, workloadIdentity: config)

        let keyed = try #require(try Gateway(providers: [withKey]).client() as? AnthropicClient)
        let federated = try #require(try Gateway(providers: [withoutKey]).client() as? AnthropicClient)

        #expect(keyed.workloadIdentity == nil)
        #expect(federated.workloadIdentity == config)
    }
}

struct ProviderEnvironmentDefaultsTests {
    let environment = [
        "ANTHROPIC_WORKSPACE_ID": "wrkspc_env",
        "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_1",
        "ANTHROPIC_ORGANIZATION_ID": "org",
        "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_1",
        "ANTHROPIC_IDENTITY_TOKEN": "jwt",
    ]

    @Test
    func anthropicProviderFillsUnsetSettingsFromEnvironment() {
        let provider = ProviderConfig(name: "a", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!)
            .withEnvironmentDefaults(environment)
        #expect(provider.workspaceID == "wrkspc_env")
        #expect(provider.workloadIdentity?.federationRuleID == "fdrl_1")
    }

    @Test
    func configuredValuesWinOverEnvironment() {
        let provider = ProviderConfig(
            name: "a", api: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, workspaceID: "wrkspc_file"
        ).withEnvironmentDefaults(environment)
        #expect(provider.workspaceID == "wrkspc_file")
    }

    @Test
    func openAIProviderIsUntouched() {
        let provider = ProviderConfig(name: "o", baseURL: URL(string: "https://api.openai.com/v1")!)
        #expect(provider.withEnvironmentDefaults(environment) == provider)
    }
}
