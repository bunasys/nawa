import AgentCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A collection of OpenAI-compatible providers with a single active provider.
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

    /// The resolved, opened client for the given provider (defaults to active).
    public func client(for providerName: String? = nil) throws -> OpenAICompatibleClient {
        let provider = providerName.flatMap { name in providers.first { $0.name == name } } ?? activeProvider
        guard let provider else { throw GatewayError.noProvider }
        let apiKey = apiKeyOverrides[provider.name] ?? provider.resolvedAPIKey
        return OpenAICompatibleClient(
            providerName: provider.name,
            baseURL: provider.baseURL,
            apiKey: apiKey,
            session: session
        )
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
                    for chunk in await self.allChunks(of: client.stream(adjusted)) {
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
    public func resolveModel(client: OpenAICompatibleClient, requested: String?) async throws -> String {
        if let requested { return requested }
        if let configured = activeProvider?.model { return configured }
        return try await autoDiscover(client: client)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoModel(client: OpenAICompatibleClient) async throws -> String {
        try await autoDiscover(client: client)
    }

    /// Auto model discovery: list models, filter by whitelist, pick the first.
    public func autoDiscover(client: OpenAICompatibleClient) async throws -> String {
        let models = try await client.listModels()
        let whitelist = activeProvider?.modelWhitelist
        let candidates = models.filter { whitelist == nil || whitelist!.contains($0.id) }
        guard let first = candidates.first ?? models.first else {
            throw GatewayError.modelNotFound("no models advertised by \(client.providerName)")
        }
        return first.id
    }
}


extension Gateway {
    /// Collect all chunks from a streaming response as an array.
    private func allChunks(of stream: AsyncThrowingStream<StreamChunk, any Error>) async -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
        } catch {
            // Final finish below reports the error via completion.
        }
        return chunks
    }
}
