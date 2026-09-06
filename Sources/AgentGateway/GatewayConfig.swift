import AgentCore
import Foundation

/// The on-disk shape of a gateway configuration file.
///
/// Example `Gateway.json`:
/// ```json
/// {
///   "activeProvider": "local-ollama",
///   "providers": [
///     { "name": "openai",        "baseURL": "https://api.openai.com/v1",     "apiKey": "env:OPENAI_API_KEY", "model": "gpt-4o-mini" },
///     { "name": "local-ollama",  "baseURL": "http://localhost:11434/v1",     "apiKey": "ollama" },
///     { "name": "vllm",          "baseURL": "http://localhost:8000/v1",      "apiKey": "token-abc", "modelWhitelist": ["qwen2.5-7b"] }
///   ]
/// }
/// ```
public struct GatewayConfig: Codable, Sendable {
    public var activeProvider: String?
    public var providers: [ProviderConfig]

    public init(activeProvider: String? = nil, providers: [ProviderConfig] = []) {
        self.activeProvider = activeProvider
        self.providers = providers
    }

    /// Build the runnable gateway from the typed config.
    public func makeGateway(apiKeyOverrides: [String: String] = [:]) -> Gateway {
        Gateway(
            providers: providers,
            activeProviderName: activeProvider,
            apiKeyOverrides: apiKeyOverrides
        )
    }

    /// Load a config from a file path.
    public static func load(fromFile path: String) throws -> GatewayConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(GatewayConfig.self, from: data)
    }

    /// Load from the `AGENT_GATEWAY_CONFIG` env var if present, else from a
    /// `Gateways.json` next to the current file, else an empty default.
    public static func loadFromEnvironmentOrFile(
        envKey configEnv: String = "AGENT_GATEWAY_CONFIG",
        fileName: String = "Gateways.json"
    ) throws -> GatewayConfig {
        if let path = ProcessInfo.processInfo.environment[configEnv] {
            return try load(fromFile: path)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try load(fromFile: candidate.path)
        }
        return GatewayConfig()
    }
}
