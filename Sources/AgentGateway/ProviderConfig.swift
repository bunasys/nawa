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
    /// Anthropic only: when a model declines a request (`stop_reason:
    /// "refusal"`), have the server retry it on the model Anthropic
    /// recommends for that refusal (`fallbacks: "default"`). Nil means on
    /// for api.anthropic.com, the only endpoint known to support it; set it
    /// to true for others that do (Claude Platform on AWS, Google Cloud).
    public var serverFallbacks: Bool?
    /// Seconds a model call may wait for its reply before failing (and the
    /// gateway moving to a fallback provider). Nil means 600. A caller that
    /// knows its replies are quick sets less, so a provider that hangs costs
    /// minutes rather than ten.
    public var requestTimeout: TimeInterval?

    public init(
        name: String,
        api: ProviderAPI? = nil,
        baseURL: URL,
        apiKey: String? = nil,
        model: String? = nil,
        modelWhitelist: [String]? = nil,
        headers: [String: String]? = nil,
        workspaceID: String? = nil,
        workloadIdentity: WorkloadIdentityConfig? = nil,
        serverFallbacks: Bool? = nil,
        requestTimeout: TimeInterval? = nil
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
        self.serverFallbacks = serverFallbacks
        self.requestTimeout = requestTimeout
    }

    /// Whether requests to this provider ask for server-side fallbacks.
    public var usesServerFallbacks: Bool {
        guard api == .anthropic else { return false }
        return serverFallbacks ?? (baseURL.host == "api.anthropic.com")
    }

    /// Resolve the api key, expanding an `env:NAME` reference.
    public var resolvedAPIKey: String? {
        apiKey.flatMap { Self.resolveAPIKey($0) }
    }

    /// Expand an API key as written in configuration: `env:NAME` reads the
    /// variable (nil when unset), anything else is the key itself.
    public static func resolveAPIKey(
        _ reference: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard reference.hasPrefix("env:") else { return reference }
        return environment[String(reference.dropFirst(4))]
    }

    /// This provider with unset Anthropic settings filled from the standard
    /// `ANTHROPIC_*` variables the official SDKs read: the workspace from
    /// `ANTHROPIC_WORKSPACE_ID` and federation from
    /// `WorkloadIdentityConfig.fromEnvironment`.
    ///
    /// Call this once, while loading configuration, so a `Gateway` built from
    /// the result behaves the same whatever the process environment later is.
    public func withEnvironmentDefaults(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderConfig {
        guard api == .anthropic else { return self }
        var resolved = self
        resolved.workspaceID = workspaceID ?? environment["ANTHROPIC_WORKSPACE_ID"]
        resolved.workloadIdentity = workloadIdentity ?? WorkloadIdentityConfig.fromEnvironment(environment)
        return resolved
    }
}
