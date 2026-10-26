import AgentCore
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A collection of providers (OpenAI-compatible or Anthropic) with a single active provider.
///
/// The Gateway is the configurable AI front door: it holds zero or more
/// `ProviderConfig`s, resolves environment-variable API keys, picks the active
/// provider, and performs *auto model discovery* — when no model is configured
/// for the active provider it queries `GET /v1/models` and selects the first
/// allowed model.
///
/// With `fallbackProviderNames`, a request the active provider can't serve
/// (rate limit, exhausted quota, outage, network or credential failure; see
/// `GatewayFailover.isProviderUnavailable`) goes to the next provider in that
/// list. A provider that failed is skipped for `GatewayFailover.cooldown`, so
/// a long review doesn't knock on a dead provider before every call.
public struct Gateway: LanguageModel, Sendable {
    public var providers: [ProviderConfig]
    public var activeProviderName: String?
    /// Providers to try, in order, when the active one can't serve a request.
    public var fallbackProviderNames: [String]
    public var apiKeyOverrides: [String: String]
    public let session: URLSession
    /// Shared by copies of this gateway, so they all skip a failed provider.
    /// A new `Gateway` starts with no cooldowns: keep one for as long as the
    /// process (or the session) runs, rather than one per request.
    let failover: GatewayFailover

    public init(
        providers: [ProviderConfig] = [],
        activeProviderName: String? = nil,
        fallbackProviderNames: [String] = [],
        apiKeyOverrides: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.providers = providers
        self.activeProviderName = activeProviderName
        self.fallbackProviderNames = fallbackProviderNames
        self.apiKeyOverrides = apiKeyOverrides
        self.session = session
        self.failover = GatewayFailover()
    }

    /// The provider the gateway routes to by default.
    public var activeProvider: ProviderConfig? {
        guard let name = activeProviderName else { return providers.first }
        return providers.first { $0.name == name }
    }

    /// The client for the given provider (defaults to active), speaking
    /// whichever wire API that provider is configured for.
    public func client(for providerName: String? = nil) throws -> any LanguageModel {
        let provider = providerName.flatMap { name in providers.first { $0.name == name } } ?? activeProvider
        guard let provider else { throw GatewayError.noProvider }
        return client(for: provider)
    }

    private func client(for provider: ProviderConfig) -> any LanguageModel {
        let apiKey = apiKeyOverrides[provider.name] ?? provider.resolvedAPIKey
        switch provider.api ?? .openAI {
        case .openAI:
            return OpenAICompatibleClient(
                providerName: provider.name, baseURL: provider.baseURL, apiKey: apiKey,
                requestTimeout: provider.requestTimeout ?? OpenAICompatibleClient.defaultRequestTimeout,
                session: session
            )
        case .anthropic:
            // Same precedence as Anthropic's SDKs: an API key shadows federation.
            // Environment fallbacks are applied when configuration is loaded
            // (`ProviderConfig.withEnvironmentDefaults`), not here.
            let workloadIdentity = apiKey == nil ? provider.workloadIdentity : nil
            return AnthropicClient(
                providerName: provider.name,
                baseURL: provider.baseURL,
                apiKey: apiKey,
                workspaceID: provider.workspaceID,
                workloadIdentity: workloadIdentity,
                serverFallbacks: provider.usesServerFallbacks,
                requestTimeout: provider.requestTimeout ?? AnthropicClient.defaultRequestTimeout,
                session: session
            )
        }
    }

    // MARK: LanguageModel

    public var providerName: String { activeProvider?.name ?? "gateway" }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try await withFailover(request) { provider, preferred, attempt in
            var response = try await client(for: provider).complete(attempt)
            response.providerName = provider.name
            response.replacedProvider = provider.name == preferred.name ? nil : preferred.name
            return response
        }
    }

    /// Fails over like `complete`, but only until the first chunk: after
    /// that the caller has seen part of a reply, so an error ends the stream.
    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var hasYielded = false
                    try await self.withFailover(request, mayFailOver: { !hasYielded }) { provider, preferred, attempt in
                        for try await chunk in self.client(for: provider).stream(attempt) {
                            hasYielded = true
                            guard case .finished(var response) = chunk else {
                                continuation.yield(chunk)
                                continue
                            }
                            response.providerName = provider.name
                            response.replacedProvider = provider.name == preferred.name ? nil : preferred.name
                            continuation.yield(.finished(response))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `call` on each provider in the chain until one succeeds. It moves
    /// on only when the provider is unavailable (not when the request itself
    /// is bad) and `mayFailOver` agrees; then that provider cools down.
    private func withFailover<T>(
        _ request: ModelRequest,
        mayFailOver: () -> Bool = { true },
        _ call: (_ provider: ProviderConfig, _ preferred: ProviderConfig, ModelRequest) async throws -> T
    ) async throws -> T {
        let preferred = try preferredProvider(for: request)
        let chain = providerChain(for: request, preferred: preferred)
        var failures: [String] = []
        let hasFallbacks = chain.count > 1
        for provider in chain {
            // Cancellation never fails over, whatever the next client would do with it.
            try Task.checkCancellation()
            do {
                // Model ids are per provider: the requested one is for the preferred provider only.
                let isPreferred = provider.name == preferred.name
                var attempt = request
                attempt.model = try await model(for: provider, client: client(for: provider), requested: isPreferred ? request.model : nil)
                return try await call(provider, preferred, attempt)
            } catch {
                // A cancelled call may surface as a network error; it says nothing about the provider.
                let isUnavailable = !Task.isCancelled && GatewayFailover.isProviderUnavailable(error)
                // Only a request that could fail over starts a cooldown: one
                // that stays on its provider doesn't reroute the others.
                if isUnavailable && hasFallbacks && GatewayFailover.startsCooldown(error) {
                    failover.markFailed(provider.name)
                }
                let isLast = provider.name == chain.last?.name
                let mayMoveOn = isUnavailable && mayFailOver()
                guard mayMoveOn && !isLast else {
                    // Summed up only when the chain ran out. A cancellation, a
                    // bad request or a stream cut off mid-reply keeps its own type.
                    let isWholeChainDown = !failures.isEmpty && mayMoveOn
                    throw isWholeChainDown ? GatewayError.providersFailed(failures + [GatewayFailover.failureLine(provider.name, error)]) : error
                }
                failures.append(GatewayFailover.failureLine(provider.name, error))
            }
        }
        // Not reached: the chain is never empty, and its last provider returns or throws.
        throw GatewayError.noProvider
    }

    /// The provider a request is meant for: the one it names, else the
    /// active one (an unknown name also means the active one, as in `client(for:)`).
    private func preferredProvider(for request: ModelRequest) throws -> ProviderConfig {
        let named = request.providerName.flatMap { name in providers.first { $0.name == name } }
        guard let provider = named ?? activeProvider else { throw GatewayError.noProvider }
        return provider
    }

    /// The providers to try, in order. A request that names a provider, or
    /// may not fail over, gets only its preferred one. Otherwise: the
    /// preferred provider, then the fallbacks, with any still cooling down
    /// from a failure moved to the end (not dropped: a provider that may
    /// have recovered beats none).
    func providerChain(for request: ModelRequest, preferred: ProviderConfig) -> [ProviderConfig] {
        let staysOnPreferred = request.providerName != nil || !request.mayFailOver
        guard !staysOnPreferred else { return [preferred] }
        var chain = [preferred]
        for name in fallbackProviderNames where !chain.contains(where: { $0.name == name }) {
            // A name with no provider behind it is skipped, like a fallback that is down.
            if let fallback = providers.first(where: { $0.name == name }) { chain.append(fallback) }
        }
        // One look at the clock for the whole chain, so no provider can fall between the two lists.
        let now = Date()
        let coolingDown = Set(chain.map(\.name).filter { failover.isCoolingDown($0, now: now) })
        return chain.filter { !coolingDown.contains($0.name) } + chain.filter { coolingDown.contains($0.name) }
    }

    public func listModels() async throws -> [ModelSummary] {
        let client = try self.client(for: nil)
        return try await client.listModels()
    }

    /// Resolve the model id to use for a request.
    ///
    /// Precedence: explicit request model → active provider's configured model
    /// → auto model discovery (`GET /v1/models`, filtered by whitelist).
    public func resolveModel(client: any LanguageModel, requested: String?) async throws -> String {
        try await model(for: activeProvider, client: client, requested: requested)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoModel(client: any LanguageModel) async throws -> String {
        try await autoDiscover(client: client)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoDiscover(client: any LanguageModel) async throws -> String {
        try await model(for: activeProvider, client: client, requested: nil, ignoringConfigured: true)
    }

    /// The model for a request to `provider` (nil: none configured), with
    /// the precedence `resolveModel` describes.
    private func model(
        for provider: ProviderConfig?,
        client: any LanguageModel,
        requested: String?,
        ignoringConfigured: Bool = false
    ) async throws -> String {
        if let requested { return requested }
        if !ignoringConfigured, let configured = provider?.model { return configured }
        let models = try await client.listModels()
        let whitelist = provider?.modelWhitelist
        let candidates = models.filter { whitelist == nil || whitelist!.contains($0.id) }
        guard let first = candidates.first ?? models.first else {
            throw GatewayError.modelNotFound("no models advertised by \(client.providerName)")
        }
        return first.id
    }
}

/// When the gateway moves a request to a fallback provider, and which
/// providers it is avoiding for now.
final class GatewayFailover: Sendable {
    /// Long enough to ride out a rate limit window; short enough that the
    /// preferred provider gets traffic back soon after it recovers.
    static let cooldown: TimeInterval = 60

    private let failedAt = Mutex<[String: Date]>([:])

    func markFailed(_ providerName: String, now: Date = Date()) {
        failedAt.withLock { $0[providerName] = now }
    }

    func isCoolingDown(_ providerName: String, now: Date = Date()) -> Bool {
        guard let failed = failedAt.withLock({ $0[providerName] }) else { return false }
        return now.timeIntervalSince(failed) < Self.cooldown
    }

    /// Longest error text kept per provider in `providersFailed`: a proxy's
    /// 502 is often a whole HTML page.
    static let maxFailureLength = 300

    /// "name: error", the error cut short.
    static func failureLine(_ providerName: String, _ error: any Error) -> String {
        let text = String(describing: error)
        let shortened = text.count > maxFailureLength ? text.prefix(maxFailureLength) + "…" : Substring(text)
        return "\(providerName): \(shortened)"
    }

    /// Whether a failure takes the whole provider out for `cooldown`. A 404
    /// is about one model, often a mistyped one: the request still fails
    /// over, but other requests keep going to the provider.
    static func startsCooldown(_ error: any Error) -> Bool {
        if case GatewayError.httpError(statusCode: 404, _) = error { return false }
        return true
    }

    /// Whether `error` means this provider can't serve requests right now,
    /// so another provider might. A request the provider rejected as
    /// malformed (most 400s) would fail anywhere, so it doesn't fail over.
    static func isProviderUnavailable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        guard let gatewayError = error as? GatewayError else { return false }
        switch gatewayError {
        case .httpError(let status, let body):
            // 404 included on purpose: a model this provider doesn't have
            // (or no longer has) is one it can't serve, even when the caller
            // named it. The fallback uses its own model, and the switch is
            // reported (`ModelResponse.providerName`), so the mistake shows.
            let isOutOfCredit = status == 400 && body.contains("credit balance")
            let isUnavailable = [401, 402, 403, 404, 408, 429].contains(status) || status >= 500
            return isUnavailable || isOutOfCredit
        case .network, .invalidResponse, .workloadIdentity, .incompleteStream:
            return true
        case .noProvider, .providerNotFound, .modelNotFound, .providersFailed:
            return false
        }
    }
}
