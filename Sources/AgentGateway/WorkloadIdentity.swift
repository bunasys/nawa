import AgentCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Workload Identity Federation: authenticate with a short-lived
/// OIDC token from an identity provider you already trust (GitHub Actions,
/// Kubernetes, AWS, Google Cloud, Entra ID, Okta, SPIFFE, …) instead of a
/// static API key.
///
/// The JWT is exchanged at `POST /v1/oauth/token` (RFC 7523 `jwt-bearer`
/// grant) for an `sk-ant-oat01-…` access token sent as `Authorization: Bearer`.
/// See https://platform.claude.com/docs/en/manage-claude/wif-reference
public struct WorkloadIdentityConfig: Sendable, Codable, Hashable {
    /// `fdrl_…` — the federation rule the JWT is evaluated against.
    public var federationRuleID: String
    /// UUID of the Anthropic organization.
    public var organizationID: String
    /// `svac_…` — the service account the minted token acts as.
    public var serviceAccountID: String
    /// `wrkspc_…` — required only when the rule spans several workspaces.
    public var workspaceID: String?
    /// Path to the JWT. Re-read on every exchange so tokens your identity
    /// provider rotates on disk are always current.
    public var identityTokenFile: String?
    /// The JWT itself, for platforms that inject it as a variable.
    public var identityToken: String?

    public init(
        federationRuleID: String,
        organizationID: String,
        serviceAccountID: String,
        workspaceID: String? = nil,
        identityTokenFile: String? = nil,
        identityToken: String? = nil
    ) {
        self.federationRuleID = federationRuleID
        self.organizationID = organizationID
        self.serviceAccountID = serviceAccountID
        self.workspaceID = workspaceID
        self.identityTokenFile = identityTokenFile
        self.identityToken = identityToken
    }

    /// The configuration from the standard `ANTHROPIC_*` variables the
    /// official SDKs read. Like the SDKs, it activates only when the rule,
    /// organization, service account and one token source are all set.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorkloadIdentityConfig? {
        guard let ruleID = environment["ANTHROPIC_FEDERATION_RULE_ID"],
              let organizationID = environment["ANTHROPIC_ORGANIZATION_ID"],
              let serviceAccountID = environment["ANTHROPIC_SERVICE_ACCOUNT_ID"]
        else { return nil }
        let tokenFile = environment["ANTHROPIC_IDENTITY_TOKEN_FILE"]
        let token = environment["ANTHROPIC_IDENTITY_TOKEN"]
        guard tokenFile != nil || token != nil else { return nil }
        return WorkloadIdentityConfig(
            federationRuleID: ruleID,
            organizationID: organizationID,
            serviceAccountID: serviceAccountID,
            workspaceID: environment["ANTHROPIC_WORKSPACE_ID"],
            identityTokenFile: tokenFile,
            identityToken: token
        )
    }

    /// The JWT to present right now.
    func readIdentityToken() throws -> String {
        if let identityTokenFile {
            do {
                let contents = try String(contentsOfFile: identityTokenFile, encoding: .utf8)
                return contents.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw GatewayError.workloadIdentity("cannot read identity token file \(identityTokenFile): \(error.localizedDescription)")
            }
        }
        if let identityToken { return identityToken }
        throw GatewayError.workloadIdentity("no identity token: set identityTokenFile or identityToken")
    }

    /// The `/v1/oauth/token` request body.
    func exchangeBody(assertion: String) -> JSON {
        var body: [String: JSON] = [
            "grant_type": .string("urn:ietf:params:oauth:grant-type:jwt-bearer"),
            "assertion": .string(assertion),
            "federation_rule_id": .string(federationRuleID),
            "organization_id": .string(organizationID),
            "service_account_id": .string(serviceAccountID),
        ]
        if let workspaceID {
            body["workspace_id"] = .string(workspaceID)
        }
        return .object(body)
    }
}

/// Exchanges identity tokens for Anthropic access tokens and caches the result.
///
/// Refresh follows the official SDKs: try a new exchange from 120 s before
/// expiry, but keep serving the cached token if that fails; from 30 s before
/// expiry a failed exchange is an error.
///
/// One source exists per (configuration, endpoint) for the whole process, via
/// `shared(for:tokenURL:session:)`. That matters beyond saving round trips:
/// identity tokens with a `jti` claim are single-use, so two clients
/// exchanging the same JWT would get the second one rejected.
public actor WorkloadIdentityTokenSource {
    static let advisoryRefreshMargin: TimeInterval = 120
    static let mandatoryRefreshMargin: TimeInterval = 30

    struct AccessToken {
        var value: String
        var expiresAt: Date
    }

    public let config: WorkloadIdentityConfig
    public let tokenURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cached: AccessToken?
    /// The exchange in flight, so concurrent callers share it rather than
    /// presenting the same JWT twice.
    private var refreshing: Task<AccessToken, any Error>?

    init(
        config: WorkloadIdentityConfig,
        tokenURL: URL,
        session: URLSession,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.config = config
        self.tokenURL = tokenURL
        self.session = session
        self.now = now
    }

    /// A valid access token, exchanging a fresh one when needed.
    public func accessToken() async throws -> String {
        let currentTime = now()
        if let cached, currentTime < cached.expiresAt.addingTimeInterval(-Self.advisoryRefreshMargin) {
            return cached.value
        }
        do {
            let fresh = try await refreshOnce()
            cached = fresh
            return fresh.value
        } catch {
            let stillSafe = cached.map { currentTime < $0.expiresAt.addingTimeInterval(-Self.mandatoryRefreshMargin) } ?? false
            if stillSafe, let cached { return cached.value }
            throw error
        }
    }

    private func refreshOnce() async throws -> AccessToken {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await exchange() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func exchange() async throws -> AccessToken {
        let assertion = try config.readIdentityToken()
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(config.exchangeBody(assertion: assertion))

        let (data, response) = try await session.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Anthropic deliberately answers every rejected assertion with the
            // same opaque 401; the real reason is in the Console's history.
            throw GatewayError.workloadIdentity(
                "token exchange failed (HTTP \(http.statusCode)): \(body). "
                    + "See https://platform.claude.com/settings/workload-identity-federation?tab=history"
            )
        }
        let fields = (try? JSONDecoder().decode(JSON.self, from: data))?.objectValue ?? [:]
        guard let token = fields["access_token"]?.stringValue,
              let expiresIn = fields["expires_in"]?.intValue
        else {
            throw GatewayError.workloadIdentity("token exchange response lacks access_token/expires_in: \(body)")
        }
        return AccessToken(value: token, expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)))
    }

    // MARK: Process-wide sharing

    private struct Key: Hashable {
        var config: WorkloadIdentityConfig
        var tokenURL: URL
    }

    private static let registry = Registry()

    private actor Registry {
        var sources: [Key: WorkloadIdentityTokenSource] = [:]

        func source(for key: Key, session: URLSession) -> WorkloadIdentityTokenSource {
            if let existing = sources[key] { return existing }
            let created = WorkloadIdentityTokenSource(config: key.config, tokenURL: key.tokenURL, session: session)
            sources[key] = created
            return created
        }
    }

    /// The process-wide source for this configuration and endpoint.
    public static func shared(
        for config: WorkloadIdentityConfig,
        tokenURL: URL,
        session: URLSession = .shared
    ) async -> WorkloadIdentityTokenSource {
        await registry.source(for: Key(config: config, tokenURL: tokenURL), session: session)
    }
}
