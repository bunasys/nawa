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
///   },
///   "settings": {
///     "/Users/me/projects/app": { "compact_at": 600000, "helper_model": "gpt-4o-mini", "skills": true }
///   }
/// }
/// ```
public struct AgentConfigStore: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by the standardized absolute path of the directory.
    public var directories: [String: GatewayConfig]
    /// `nawa config set` values, keyed like `directories`.
    ///
    /// Added without a version bump: older builds ignore the field. They
    /// would drop it if they saved the file (`nawa config add/use/remove`),
    /// which is better than a bump that would stop them reading their
    /// providers at all.
    public var settings: [String: DirectorySettings]

    public init(
        version: Int = AgentConfigStore.currentVersion,
        directories: [String: GatewayConfig] = [:],
        settings: [String: DirectorySettings] = [:]
    ) {
        self.version = version
        self.directories = directories
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case version, directories, settings }

    /// Files written before settings existed have no `settings` field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        directories = try container.decode([String: GatewayConfig].self, forKey: .directories)
        settings = try container.decodeIfPresent([String: DirectorySettings].self, forKey: .settings) ?? [:]
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
    /// malformed one throws `AgentConfigStoreError.malformed`, and one from a
    /// newer version `.unsupportedVersion`.
    public static func load(from url: URL = defaultLocation()) throws -> AgentConfigStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentConfigStore() }
        let data = try Data(contentsOf: url)
        let store: AgentConfigStore
        do {
            store = try JSONDecoder().decode(AgentConfigStore.self, from: data)
        } catch {
            throw AgentConfigStoreError.malformed(path: url.path, underlying: error)
        }
        // A newer format may mean fields this build would silently drop on
        // the next save, so refuse it rather than lose the user's settings.
        guard store.version <= currentVersion else {
            throw AgentConfigStoreError.unsupportedVersion(path: url.path, version: store.version)
        }
        return store
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

    /// The settings saved for `directory` (none set when nothing was saved).
    public func settings(for directory: URL) -> DirectorySettings {
        settings[Self.key(for: directory)] ?? DirectorySettings()
    }

    /// Change `directory`'s settings in place; a directory left with
    /// nothing set is removed from the file.
    public mutating func updateSettings(for directory: URL, _ change: (inout DirectorySettings) -> Void) {
        let key = Self.key(for: directory)
        var values = settings[key] ?? DirectorySettings()
        change(&values)
        settings[key] = values == DirectorySettings() ? nil : values
    }

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

/// What `nawa config set` saves for one directory: the agent loop's
/// settings (`LoopSettings`, the contract other programs use too) and the
/// CLI's own. Nil means "not set": the default, or the environment, decides.
///
/// In the file, the loop's fields sit next to the CLI's, not nested:
/// `{ "compact_at": 600000, "skills": false }`.
public struct DirectorySettings: Codable, Sendable, Equatable {
    public var loop: LoopSettings
    /// Offer skills to the model.
    public var skills: Bool?
    /// Include the project's skills, not only the user's.
    public var projectSkills: Bool?
    /// Record sessions as journals.
    public var sessions: Bool?
    /// Where journals go.
    public var sessionsDirectory: String?
    /// `serve`: unload a session idle this long.
    public var sessionIdleMinutes: Double?

    public init(
        loop: LoopSettings = LoopSettings(),
        skills: Bool? = nil,
        projectSkills: Bool? = nil,
        sessions: Bool? = nil,
        sessionsDirectory: String? = nil,
        sessionIdleMinutes: Double? = nil
    ) {
        self.loop = loop
        self.skills = skills
        self.projectSkills = projectSkills
        self.sessions = sessions
        self.sessionsDirectory = sessionsDirectory
        self.sessionIdleMinutes = sessionIdleMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case skills
        case projectSkills = "project_skills"
        case sessions
        case sessionsDirectory = "sessions_dir"
        case sessionIdleMinutes = "session_idle_minutes"
    }

    // The loop's fields are read from and written to the same JSON object.
    public init(from decoder: any Decoder) throws {
        loop = try LoopSettings(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decodeIfPresent(Bool.self, forKey: .skills)
        projectSkills = try container.decodeIfPresent(Bool.self, forKey: .projectSkills)
        sessions = try container.decodeIfPresent(Bool.self, forKey: .sessions)
        sessionsDirectory = try container.decodeIfPresent(String.self, forKey: .sessionsDirectory)
        sessionIdleMinutes = try container.decodeIfPresent(Double.self, forKey: .sessionIdleMinutes)
    }

    public func encode(to encoder: any Encoder) throws {
        try loop.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(skills, forKey: .skills)
        try container.encodeIfPresent(projectSkills, forKey: .projectSkills)
        try container.encodeIfPresent(sessions, forKey: .sessions)
        try container.encodeIfPresent(sessionsDirectory, forKey: .sessionsDirectory)
        try container.encodeIfPresent(sessionIdleMinutes, forKey: .sessionIdleMinutes)
    }

    /// These settings with every field `other` sets replacing this one's.
    public func overlaid(by other: DirectorySettings) -> DirectorySettings {
        DirectorySettings(
            loop: loop.overlaid(by: other.loop),
            skills: other.skills ?? skills,
            projectSkills: other.projectSkills ?? projectSkills,
            sessions: other.sessions ?? sessions,
            sessionsDirectory: other.sessionsDirectory ?? sessionsDirectory,
            sessionIdleMinutes: other.sessionIdleMinutes ?? sessionIdleMinutes
        )
    }
}

public enum AgentConfigStoreError: Error, LocalizedError, Sendable {
    case malformed(path: String, underlying: any Error)
    case providerNotFound(name: String, directory: String)
    case unsupportedVersion(path: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let path, let underlying):
            return "config file at \(path) is not valid: \(underlying)"
        case .providerNotFound(let name, let directory):
            return "no provider named \"\(name)\" is configured for \(directory)"
        case .unsupportedVersion(let path, let version):
            return "config file at \(path) is version \(version); this nawa reads up to \(AgentConfigStore.currentVersion). Upgrade nawa."
        }
    }
}
