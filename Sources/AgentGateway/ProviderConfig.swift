import AgentCore
import Foundation

/// The wire API a provider speaks.
public enum ProviderAPI: String, Sendable, Codable, CaseIterable {
    /// OpenAI chat completions (`/chat/completions`, `Authorization: Bearer`).
    case openAI = "openai"
    /// Anthropic Messages (`/v1/messages`, `x-api-key`).
    case anthropic
}

/// A provider configuration (one entry under `providers` in `Gateways.json`).
public struct ProviderConfig: Sendable, Codable, Equatable {
    /// Stable id used to select this provider (e.g. "openai", "my-vllm").
    public var name: String
    /// Which wire API the provider speaks. `nil` means `.openAI`, so config
    /// files written before Anthropic support keep working.
    public var api: ProviderAPI?
    /// Base URL of the API (e.g. `https://api.openai.com/v1`, `https://api.anthropic.com`).
    public var baseURL: URL
    /// API key. May be a literal or an env var name with `env:` prefix.
    public var apiKey: String?
    /// Optional default model id for this provider.
    public var model: String?
    /// Optional models to auto-select among; if empty, discovered at runtime.
    public var modelWhitelist: [String]?
    /// Optional per-provider HTTP headers.
    public var headers: [String: String]?
    /// Anthropic only: the `wrkspc_…` workspace requests act in. Required for
    /// API keys not scoped to a single workspace; falls back to
    /// `ANTHROPIC_WORKSPACE_ID`.
    public var workspaceID: String?
    /// Anthropic only: authenticate with Workload Identity Federation instead
    /// of an API key. When neither is set, the standard `ANTHROPIC_*`
    /// federation environment variables are used if present.
    public var workloadIdentity: WorkloadIdentityConfig?

    public init(
        name: String,
        api: ProviderAPI? = nil,
        baseURL: URL,
        apiKey: String? = nil,
        model: String? = nil,
        modelWhitelist: [String]? = nil,
        headers: [String: String]? = nil,
        workspaceID: String? = nil,
        workloadIdentity: WorkloadIdentityConfig? = nil
    ) {
        self.name = name
        self.api = api
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.modelWhitelist = modelWhitelist
        self.headers = headers
        self.workspaceID = workspaceID
        self.workloadIdentity = workloadIdentity
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
