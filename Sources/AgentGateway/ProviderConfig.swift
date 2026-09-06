import AgentCore
import Foundation

/// A provider configuration (one entry under `providers` in `Gateways.json`).
public struct ProviderConfig: Sendable, Codable, Equatable {
    /// Stable id used to select this provider (e.g. "openai", "my-vllm").
    public var name: String
    /// Base URL of the OpenAI-compatible API (e.g. `https://api.openai.com/v1`).
    public var baseURL: URL
    /// API key. May be a literal or an env var name with `env:` prefix.
    public var apiKey: String?
    /// Optional default model id for this provider.
    public var model: String?
    /// Optional models to auto-select among; if empty, discovered at runtime.
    public var modelWhitelist: [String]?
    /// Optional per-provider HTTP headers.
    public var headers: [String: String]?

    public init(
        name: String,
        baseURL: URL,
        apiKey: String? = nil,
        model: String? = nil,
        modelWhitelist: [String]? = nil,
        headers: [String: String]? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.modelWhitelist = modelWhitelist
        self.headers = headers
    }

    /// Resolve the api key, expanding an `env:NAME` reference.
    public var resolvedAPIKey: String? {
        guard let apiKey else { return nil }
        if apiKey.hasPrefix("env:") {
            let name = String(apiKey.dropFirst(4))
            return ProcessInfo.processInfo.environment[name]
        }
        return apiKey
    }
}
