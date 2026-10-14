import AgentCore
import Foundation

/// The persisted, per-directory gateway configuration written by `nawa config`.
///
/// One file holds the configuration for every project directory the user has
/// configured. Each directory owns its own `GatewayConfig`, i.e. one or more
/// providers plus the name of the active one, so a single directory can carry
/// several provider/model setups and switch between them.
///
/// Default location (first match wins):
/// 1. `$NAWA_CONFIG_FILE`
/// 2. `$XDG_CONFIG_HOME/nawa/config.json`
/// 3. `~/.config/nawa/config.json`
///
/// Example `config.json`:
/// ```json
/// {
///   "version": 1,
///   "directories": {
///     "/Users/me/projects/app": {
///       "activeProvider": "openai",
///       "providers": [
///         { "name": "openai", "baseURL": "https://api.openai.com/v1", "apiKey": "env:OPENAI_API_KEY", "model": "gpt-4o-mini" },
///         { "name": "localhost", "baseURL": "http://localhost:11434/v1", "model": "llama3.2" }
///       ]
///     }
///   }
/// }
/// ```
public struct AgentConfigStore: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by the standardized absolute path of the directory.
    public var directories: [String: GatewayConfig]

    public init(version: Int = AgentConfigStore.currentVersion, directories: [String: GatewayConfig] = [:]) {
        self.version = version
        self.directories = directories
    }

    // MARK: Location

    /// Resolve the default config file location from the environment.
    public static func defaultLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["NAWA_CONFIG_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let configHome: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = URL(fileURLWithPath: xdg)
        } else {
            configHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return configHome.appendingPathComponent("nawa").appendingPathComponent("config.json")
    }

    /// The canonical key under which a directory's configuration is stored.
    public static func key(for directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Load / save

    /// Load the store from `url`. A missing file yields an empty store; a
    /// malformed one throws `AgentConfigStoreError.malformed`.
    public static func load(from url: URL = defaultLocation()) throws -> AgentConfigStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentConfigStore() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(AgentConfigStore.self, from: data)
        } catch {
            throw AgentConfigStoreError.malformed(path: url.path, underlying: error)
        }
    }

    /// Write the store to `url`, creating parent directories as needed. The
    /// file may contain API keys, so it is written owner-read/write only.
    public func save(to url: URL = defaultLocation()) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Per-directory access

    /// The gateway configuration for `directory`, if any has been saved.
    public func gatewayConfig(for directory: URL) -> GatewayConfig? {
        directories[Self.key(for: directory)]
    }

    /// Add (or replace, by name) a provider for `directory`. When `activate`
    /// is true the provider becomes the directory's active provider.
    public mutating func addProvider(_ provider: ProviderConfig, for directory: URL, activate: Bool = true) {
        let key = Self.key(for: directory)
        var config = directories[key] ?? GatewayConfig()
        if let index = config.providers.firstIndex(where: { $0.name == provider.name }) {
            config.providers[index] = provider
        } else {
            config.providers.append(provider)
        }
        if activate || config.activeProvider == nil {
            config.activeProvider = provider.name
        }
        directories[key] = config
    }

    /// Make the named provider the active one for `directory`.
    public mutating func activateProvider(named name: String, for directory: URL) throws {
        let key = Self.key(for: directory)
        guard var config = directories[key],
              config.providers.contains(where: { $0.name == name })
        else { throw AgentConfigStoreError.providerNotFound(name: name, directory: key) }
        config.activeProvider = name
        directories[key] = config
    }

    /// Remove the named provider from `directory`. If it was active, the first
    /// remaining provider becomes active; an emptied directory is dropped.
    public mutating func removeProvider(named name: String, for directory: URL) throws {
        let key = Self.key(for: directory)
        guard var config = directories[key],
              let index = config.providers.firstIndex(where: { $0.name == name })
        else { throw AgentConfigStoreError.providerNotFound(name: name, directory: key) }
        config.providers.remove(at: index)
        if config.activeProvider == name {
            config.activeProvider = config.providers.first?.name
        }
        directories[key] = config.providers.isEmpty ? nil : config
    }
}

public enum AgentConfigStoreError: Error, LocalizedError, Sendable {
    case malformed(path: String, underlying: any Error)
    case providerNotFound(name: String, directory: String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let path, let underlying):
            return "config file at \(path) is not valid: \(underlying)"
        case .providerNotFound(let name, let directory):
            return "no provider named \"\(name)\" is configured for \(directory)"
        }
    }
}
