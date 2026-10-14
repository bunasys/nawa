import AgentGateway
import Foundation

/// `nawa config` — interactively configure a provider (OpenAI-compatible or
/// Anthropic) for the current directory and persist it to the default config location.
///
/// ```
/// nawa config              # add a provider: API → base URL → API key → pick a model → name
/// nawa config list         # show the providers configured for this directory
/// nawa config use <name>   # switch the active provider for this directory
/// nawa config remove <name>
/// ```
enum ConfigCommand {
    static func run(arguments: [String]) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let location = AgentConfigStore.defaultLocation()
        var store = try AgentConfigStore.load(from: location)

        switch arguments.first {
        case nil, "add":
            try await add(to: &store, directory: directory)
            try store.save(to: location)
            print("Saved to \(location.path)")
        case "list":
            list(store, directory: directory, location: location)
        case "use":
            guard arguments.count > 1 else { return usage() }
            try store.activateProvider(named: arguments[1], for: directory)
            try store.save(to: location)
            print("Active provider for \(directory.path) is now \"\(arguments[1])\".")
        case "remove":
            guard arguments.count > 1 else { return usage() }
            try store.removeProvider(named: arguments[1], for: directory)
            try store.save(to: location)
            print("Removed provider \"\(arguments[1])\" from \(directory.path).")
        default:
            usage()
        }
    }

    static func usage() {
        print("Usage: nawa config [add|list|use <name>|remove <name>]")
        print("  add            — (default) interactively add a provider for the current directory")
        print("  list           — show the providers configured for the current directory")
        print("  use <name>     — make <name> the active provider for the current directory")
        print("  remove <name>  — delete <name> from the current directory's configuration")
    }

    // MARK: add

    static func add(to store: inout AgentConfigStore, directory: URL) async throws {
        let existing = store.gatewayConfig(for: directory)
        print("Configuring a provider for \(directory.path)")
        if let existing, !existing.providers.isEmpty {
            let names = existing.providers.map(\.name).joined(separator: ", ")
            print("Already configured here: \(names) (active: \(existing.activeProvider ?? "none"))")
        }
        print()

        let api = promptAPI()
        let baseURL = promptBaseURL(api: api)
        let apiKey = promptAPIKey()
        let workloadIdentity = api == .anthropic && apiKey == nil ? promptWorkloadIdentity() : nil
        let workspaceID = api == .anthropic && apiKey != nil ? promptWorkspaceID() : nil

        let probe = ProviderConfig(
            name: "config", api: api, baseURL: baseURL, apiKey: apiKey?.resolvedKey,
            workspaceID: workspaceID, workloadIdentity: workloadIdentity
        )
        let client = try Gateway(providers: [probe]).client()
        print("\nFetching models from \(baseURL.absoluteString) …")
        let model: String
        do {
            let models = try await client.listModels().map(\.id).sorted()
            model = try chooseModel(from: models)
        } catch {
            print("Could not list models: \(error)")
            model = try Prompt.required("Model id (typed manually)")
        }

        let name = promptName(
            defaultName: Self.defaultName(for: baseURL, taken: existing?.providers.map(\.name) ?? [])
        )
        if existing?.providers.contains(where: { $0.name == name }) == true {
            guard Prompt.confirm("A provider named \"\(name)\" exists here. Replace it?", default: false) else {
                throw ConfigCommandError.cancelled
            }
        }

        let provider = ProviderConfig(
            name: name, api: api, baseURL: baseURL, apiKey: apiKey?.stored, model: model,
            workspaceID: workspaceID, workloadIdentity: workloadIdentity
        )
        store.addProvider(provider, for: directory, activate: true)

        print()
        print("Provider \"\(name)\" (\(api.rawValue)) → \(baseURL.absoluteString), model \(model), now active for this directory.")
        if workloadIdentity != nil {
            print("Authenticates with Workload Identity Federation (token exchanged at \(baseURL.absoluteString)).")
        } else if apiKey == nil {
            print("No API key stored; the provider will be called unauthenticated.")
        }
    }

    static func promptAPI() -> ProviderAPI {
        let choices = ProviderAPI.allCases.map(\.rawValue).joined(separator: "/")
        while true {
            let answer = Prompt.line("API (\(choices))", default: ProviderAPI.openAI.rawValue).lowercased()
            if let api = ProviderAPI(rawValue: answer) { return api }
            print("Enter one of: \(choices)")
        }
    }

    static func promptBaseURL(api: ProviderAPI) -> URL {
        let suggested = api == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        while true {
            let raw = Prompt.line("Base URL", default: suggested)
            let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
               url.host != nil {
                return url
            }
            print("Please enter an absolute http(s) URL, e.g. http://localhost:11434/v1")
        }
    }

    /// The API key as typed. `env:NAME` references are kept verbatim so the
    /// secret never lands on disk; literal keys are stored as-is.
    struct APIKeyInput {
        var stored: String
        var resolvedKey: String? {
            ProviderConfig(name: "", baseURL: URL(fileURLWithPath: "/"), apiKey: stored).resolvedAPIKey
        }
    }

    static func promptAPIKey() -> APIKeyInput? {
        let typed = Prompt.secret("API key (hidden; empty for none, or env:NAME to reference an env var)")
        guard !typed.isEmpty else { return nil }
        let input = APIKeyInput(stored: typed)
        if typed.hasPrefix("env:"), input.resolvedKey == nil {
            print("Note: \(typed.dropFirst(4)) is not set in the current environment; it will be read at run time.")
        }
        return input
    }

    /// Anthropic API keys not scoped to one workspace must name the workspace
    /// on every request.
    static func promptWorkspaceID() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_WORKSPACE_ID"] ?? ""
        let answer = Prompt.line(
            "Workspace ID (wrkspc_…, empty if the key is scoped to one workspace)", default: fromEnvironment
        )
        return answer.isEmpty ? nil : answer
    }

    /// Anthropic Workload Identity Federation: identifiers only — the JWT is
    /// read from a file on every exchange, so no secret is stored. Defaults
    /// come from the `ANTHROPIC_*` variables the official SDKs use.
    static func promptWorkloadIdentity() -> WorkloadIdentityConfig? {
        let fromEnvironment = WorkloadIdentityConfig.fromEnvironment()
        let question = "Authenticate with Workload Identity Federation (OIDC identity token)?"
        guard Prompt.confirm(question, default: fromEnvironment != nil) else { return nil }

        let ruleID = Prompt.line("Federation rule ID (fdrl_…)", default: fromEnvironment?.federationRuleID)
        let organizationID = Prompt.line("Organization ID (UUID)", default: fromEnvironment?.organizationID)
        let serviceAccountID = Prompt.line("Service account ID (svac_…)", default: fromEnvironment?.serviceAccountID)
        let workspaceID = Prompt.line(
            "Workspace ID (wrkspc_…, empty if the rule has one workspace)", default: fromEnvironment?.workspaceID ?? ""
        )
        let tokenFile = Prompt.line(
            "Path to the identity token (JWT) file", default: fromEnvironment?.identityTokenFile
        )
        return WorkloadIdentityConfig(
            federationRuleID: ruleID,
            organizationID: organizationID,
            serviceAccountID: serviceAccountID,
            workspaceID: workspaceID.isEmpty ? nil : workspaceID,
            identityTokenFile: tokenFile
        )
    }

    static func chooseModel(from models: [String]) throws -> String {
        guard !models.isEmpty else { throw ConfigCommandError.noModels }
        print("Available models:")
        for (index, id) in models.enumerated() {
            print(String(format: "  %3d. %@", index + 1, id))
        }
        while true {
            let answer = Prompt.line("Choose a model (number or id)", default: "1")
            if let number = Int(answer), (1...models.count).contains(number) {
                return models[number - 1]
            }
            if models.contains(answer) { return answer }
            print("Enter a number between 1 and \(models.count), or one of the listed ids.")
        }
    }

    static func promptName(defaultName: String) -> String {
        while true {
            let name = Prompt.line("Name for this provider", default: defaultName)
            if name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return name }
            print("Names cannot contain whitespace.")
        }
    }

    /// A readable default name derived from the host, e.g. `api.openai.com` →
    /// `openai`, `localhost:11434` → `localhost`; suffixed if already taken.
    static func defaultName(for baseURL: URL, taken: [String]) -> String {
        let host = baseURL.host ?? "provider"
        let parts = host.split(separator: ".").map(String.init)
        var base: String
        if host == "localhost" || parts.allSatisfy({ Int($0) != nil }) || host.contains(":") {
            base = "local"  // localhost, IPv4 or IPv6 literal
        } else if parts.count >= 2 {
            base = parts[parts.count - 2]
            if ["co", "com", "net", "org"].contains(base), parts.count >= 3 { base = parts[parts.count - 3] }
        } else {
            base = host
        }
        var candidate = base
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: list

    static func list(_ store: AgentConfigStore, directory: URL, location: URL) {
        guard let config = store.gatewayConfig(for: directory), !config.providers.isEmpty else {
            print("No providers configured for \(directory.path). Run `nawa config` to add one.")
            return
        }
        print("Providers for \(directory.path) (\(location.path)):")
        for provider in config.providers {
            let marker = provider.name == config.activeProvider ? "*" : " "
            var key = provider.apiKey.map { $0.hasPrefix("env:") ? $0 : "(stored)" } ?? "(none)"
            if provider.apiKey == nil, provider.workloadIdentity != nil { key = "(workload identity)" }
            let api = (provider.api ?? .openAI).rawValue
            print("  \(marker) \(provider.name)  \(api)  \(provider.baseURL.absoluteString)  model=\(provider.model ?? "auto")  key=\(key)")
        }
    }
}

enum ConfigCommandError: Error, LocalizedError {
    case cancelled
    case noModels
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .cancelled: return "cancelled"
        case .noModels: return "the provider advertised no models"
        case .inputClosed: return "no input available (stdin closed)"
        }
    }
}

// MARK: - Terminal prompts

enum Prompt {
    /// Ask for a line of input, returning `default` on an empty answer.
    static func line(_ label: String, default defaultValue: String? = nil) -> String {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        while true {
            print("\(label)\(suffix): ", terminator: "")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                print()
                fatalErrorInputClosed()
            }
            if !answer.isEmpty { return answer }
            if let defaultValue { return defaultValue }
        }
    }

    /// Ask for a non-empty line of input.
    static func required(_ label: String) throws -> String {
        line(label)
    }

    /// Ask for a secret; echo is disabled when stdin is a terminal.
    static func secret(_ label: String) -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            return line(label, default: "")
        }
        guard let raw = getpass("\(label): ") else { fatalErrorInputClosed() }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func confirm(_ label: String, default defaultValue: Bool) -> Bool {
        let answer = line("\(label) (\(defaultValue ? "Y/n" : "y/N"))", default: defaultValue ? "y" : "n")
        return answer.lowercased().hasPrefix("y")
    }

    private static func fatalErrorInputClosed() -> Never {
        FileHandle.standardError.write(Data("nawa config: \(ConfigCommandError.inputClosed.localizedDescription)\n".utf8))
        exit(1)
    }
}
