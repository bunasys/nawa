import AgentCore
import Foundation

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
public struct Gateway: LanguageModel, Sendable {
    public var providers: [ProviderConfig]
    public var activeProviderName: String?
    public var apiKeyOverrides: [String: String]
    public let session: URLSession

    public init(
        providers: [ProviderConfig] = [],
        activeProviderName: String? = nil,
        apiKeyOverrides: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.providers = providers
        self.activeProviderName = activeProviderName
        self.apiKeyOverrides = apiKeyOverrides
        self.session = session
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
        let apiKey = apiKeyOverrides[provider.name] ?? provider.resolvedAPIKey
        switch provider.api ?? .openAI {
        case .openAI:
            return OpenAICompatibleClient(
                providerName: provider.name, baseURL: provider.baseURL, apiKey: apiKey, session: session
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
                session: session
            )
        }
    }

    // MARK: LanguageModel

    public var providerName: String { activeProvider?.name ?? "gateway" }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let client = try self.client(for: request.providerName)
        let model = try await resolveModel(client: client, requested: request.model)
        var adjusted = request
        adjusted.model = model
        return try await client.complete(adjusted)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try self.client(for: request.providerName)
                    let model = try await self.resolveModel(client: client, requested: request.model)
                    var adjusted = request
                    adjusted.model = model
                    for try await chunk in client.stream(adjusted) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        if let requested { return requested }
        if let configured = activeProvider?.model { return configured }
        return try await autoDiscover(client: client)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoModel(client: any LanguageModel) async throws -> String {
        try await autoDiscover(client: client)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoDiscover(client: any LanguageModel) async throws -> String {
        let models = try await client.listModels()
        let whitelist = activeProvider?.modelWhitelist
        let candidates = models.filter { whitelist == nil || whitelist!.contains($0.id) }
        guard let first = candidates.first ?? models.first else {
            throw GatewayError.modelNotFound("no models advertised by \(client.providerName)")
        }
        return first.id
    }
}

