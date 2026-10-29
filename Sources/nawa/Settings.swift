import AgentCore
import AgentGateway
import AgentLoop
import AgentTUI
import Foundation

/// A setting as people type it: `/config set compact_at 200k`. Each one
/// reads and writes one typed field of `DirectorySettings`, the contract
/// `nawa config` saves.
///
/// Each also has the environment variable that set it before settings
/// existed. That variable still wins when it is set, so scripts and CI keep
/// working; nobody needs it otherwise.
struct Setting {
    enum TakesEffect: String {
        case now = "now"
        case nextConversation = "on /clear or in the next session"
        case nextStart = "the next time nawa starts"
    }

    let key: String
    let environmentName: String
    /// What the setting is when nothing sets it, as shown by `/config`.
    let defaultValue: String
    let takesEffect: TakesEffect
    let summary: String
    /// Parses typed text into its field; throws `SettingError` for text it can't use.
    let set: (inout DirectorySettings, String) throws -> Void
    let unset: (inout DirectorySettings) -> Void
    /// The field's value as `/config` shows it, or nil when it isn't set.
    let shown: (DirectorySettings) -> String?

    /// A setting for one optional field: `parse` turns typed text into its
    /// value, `show` turns the value back into text.
    init<Value>(
        _ key: String,
        _ environmentName: String,
        field: WritableKeyPath<DirectorySettings, Value?>,
        parse: @escaping (String) throws -> Value,
        show: @escaping (Value) -> String,
        defaultValue: String,
        takesEffect: TakesEffect,
        summary: String
    ) {
        self.key = key
        self.environmentName = environmentName
        self.defaultValue = defaultValue
        self.takesEffect = takesEffect
        self.summary = summary
        self.set = { settings, text in settings[keyPath: field] = try parse(text) }
        self.unset = { settings in settings[keyPath: field] = nil }
        self.shown = { settings in settings[keyPath: field].map(show) }
    }
}

struct SettingError: Error {
    var message: String
}

enum Settings {
    /// Every setting, in `/config` order. Computed, not stored: a `Setting`
    /// holds closures, and a list built on demand needs no locking.
    static var all: [Setting] {
        [
            Setting("compact_at", "NAWA_COMPACT_AT", field: \.loop.compactAt, parse: parseTokens, show: Format.tokens,
                    defaultValue: "120k", takesEffect: .now,
                    summary: "summarize older messages once a request reaches this many tokens"),
            Setting("helper_model", "NAWA_HELPER_MODEL", field: \.loop.helperModel, parse: parseText, show: { $0 },
                    defaultValue: "the session's model", takesEffect: .now,
                    summary: "cheaper model for sub-agents and summaries (same provider)"),
            Setting("price", "NAWA_PRICE", field: \.loop.price, parse: parsePrice, show: showPrice,
                    defaultValue: "none: no cost estimates", takesEffect: .now,
                    summary: "\"input,output\" USD per million tokens of the main model"),
            Setting("helper_price", "NAWA_HELPER_PRICE", field: \.loop.helperPrice, parse: parsePrice, show: showPrice,
                    defaultValue: "priced like the main model", takesEffect: .now,
                    summary: "\"input,output\" USD per million tokens of helper_model"),
            Setting("max_budget_usd", "NAWA_MAX_BUDGET_USD", field: \.loop.maxBudgetUSD, parse: parsePositiveNumber, show: showNumber,
                    defaultValue: "none", takesEffect: .now,
                    summary: "stop a prompt once the session's estimated cost reaches this (needs price)"),
            Setting("fallback_model", "NAWA_FALLBACK_MODEL", field: \.loop.fallbackModel, parse: parseText, show: { $0 },
                    defaultValue: "the provider's recommendation", takesEffect: .now,
                    summary: "model to retry on when the model declines a prompt (same provider)"),
            Setting("stream", "NAWA_STREAM", field: \.loop.stream, parse: parseOnOff, show: showOnOff,
                    defaultValue: "on", takesEffect: .now,
                    summary: "show replies as they arrive"),
            Setting("skills", "NAWA_SKILLS", field: \.skills, parse: parseOnOff, show: showOnOff,
                    defaultValue: "on", takesEffect: .nextConversation,
                    summary: "offer skills (SKILL.md folders) to the model"),
            Setting("project_skills", "NAWA_PROJECT_SKILLS", field: \.projectSkills, parse: parseOnOff, show: showOnOff,
                    defaultValue: "on", takesEffect: .nextConversation,
                    summary: "include the project's skills, not only yours (off for repositories you don't trust)"),
            Setting("sessions", "NAWA_SESSIONS", field: \.sessions, parse: parseOnOff, show: showOnOff,
                    defaultValue: "on", takesEffect: .nextStart,
                    summary: "record sessions as journals (needed for --resume and session/load)"),
            Setting("sessions_dir", "NAWA_SESSIONS_DIR", field: \.sessionsDirectory, parse: parsePath, show: { $0 },
                    defaultValue: "~/.local/state/nawa/sessions", takesEffect: .nextStart,
                    summary: "where session journals are written"),
            Setting("session_idle_minutes", "NAWA_SESSION_IDLE_MINUTES", field: \.sessionIdleMinutes, parse: parsePositiveNumber, show: showNumber,
                    defaultValue: "30", takesEffect: .nextStart,
                    summary: "serve: unload a session after this long without a prompt"),
        ]
    }

    static func named(_ key: String) -> Setting? {
        all.first { $0.key == key.lowercased() }
    }

    // MARK: What a session runs with

    /// `directory`'s saved settings, with any set environment variable
    /// winning over its saved value.
    static func resolved(
        for directory: URL,
        store: AgentConfigStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DirectorySettings {
        store.settings(for: directory).overlaid(by: fromEnvironment(environment))
    }

    /// The same, reading the store from its default location. A store that
    /// can't be read adds nothing: `resolveGateway` reports that problem.
    static func resolved(for directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> DirectorySettings {
        let location = AgentConfigStore.defaultLocation(environment: environment)
        let store = (try? AgentConfigStore.load(from: location)) ?? AgentConfigStore()
        return resolved(for: directory, store: store, environment: environment)
    }

    /// The settings the environment variables give. A value that doesn't
    /// parse is reported on stderr (never stdout: `acp` speaks there) and
    /// left out.
    static func fromEnvironment(_ environment: [String: String], reportProblems: Bool = true) -> DirectorySettings {
        var settings = DirectorySettings()
        for setting in all {
            guard let text = environment[setting.environmentName] else { continue }
            do {
                try setting.set(&settings, text)
            } catch {
                let message = (error as? SettingError)?.message ?? "\(error)"
                if reportProblems {
                    FileHandle.standardError.write(Data("nawa: ignoring \(setting.environmentName)=\(text): \(message)\n".utf8))
                }
            }
        }
        return settings
    }

    /// A combination of settings that doesn't work, said once: at startup
    /// and after a `/config` change, never while a turn draws.
    static func problem(with settings: DirectorySettings) -> String? {
        guard settings.loop.maxBudgetUSD != nil, settings.loop.price == nil else { return nil }
        return "max_budget_usd has no effect without price (set price to \"input,output\" USD per million tokens)"
    }

    // MARK: Typed text

    /// `120000`, `120k`, `1.5M` (any case), at least 10k.
    static func parseTokens(_ text: String) throws -> Int {
        guard let tokens = tokenCount(text), tokens >= 10_000 else {
            throw SettingError(message: "expected a token count of at least 10k, like 120k or 1.5M, not \"\(text)\"")
        }
        return tokens
    }

    static func tokenCount(_ text: String) -> Int? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        let multipliers: [(suffix: String, factor: Double)] = [("k", 1_000), ("m", 1_000_000)]
        for (suffix, factor) in multipliers where lower.hasSuffix(suffix) {
            guard let number = Double(lower.dropLast()), number > 0 else { return nil }
            return Int((number * factor).rounded())
        }
        return Int(lower)
    }

    /// `"3,15"`: input and output USD per million tokens.
    static func parsePrice(_ text: String) throws -> TokenPrice {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let input = parts[0], let output = parts[1], input >= 0, output >= 0 else {
            throw SettingError(message: "expected \"input,output\" USD per million tokens, like 3,15, not \"\(text)\"")
        }
        return TokenPrice(inputPerMillion: input, outputPerMillion: output)
    }

    static func showPrice(_ price: TokenPrice) -> String {
        "\(showNumber(price.inputPerMillion)),\(showNumber(price.outputPerMillion))"
    }

    static func parsePositiveNumber(_ text: String) throws -> Double {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number > 0 else {
            throw SettingError(message: "expected a positive number, not \"\(text)\"")
        }
        return number
    }

    /// `3` rather than `3.0`.
    static func showNumber(_ number: Double) -> String {
        let isWhole = number == number.rounded() && abs(number) < 1e15
        return isWhole ? String(Int(number)) : String(number)
    }

    static func parseOnOff(_ text: String) throws -> Bool {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["on", "true", "yes", "1"].contains(lower) { return true }
        if ["off", "false", "no", "0"].contains(lower) { return false }
        throw SettingError(message: "expected on or off, not \"\(text)\"")
    }

    static func showOnOff(_ value: Bool) -> String { value ? "on" : "off" }

    static func parseText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw SettingError(message: "expected a value") }
        return trimmed
    }

    static func parsePath(_ text: String) throws -> String {
        (try parseText(text) as NSString).expandingTildeInPath
    }

    // MARK: The command

    /// `/config` and `nawa config settings|set|unset`, given the words after
    /// the command. Returns the lines to show. Saves to the store at
    /// `location`; the caller applies what takes effect now. `inSession` is
    /// true for `/config`, whose session applies changes at once; from the
    /// command line they reach new sessions only.
    static func command(
        _ arguments: [String],
        directory: URL,
        location: URL = AgentConfigStore.defaultLocation(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inSession: Bool = false
    ) -> [String] {
        do {
            var store = try AgentConfigStore.load(from: location)
            switch arguments.first?.lowercased() {
            case nil, "settings", "list":
                return report(store: store, directory: directory, location: location, environment: environment)
            case "set":
                guard arguments.count >= 3 else { return ["usage: set <key> <value>"] }
                guard let setting = named(arguments[1]) else { return ["unknown setting \(arguments[1]); /config lists them"] }
                var changed = store.settings(for: directory)
                do {
                    try setting.set(&changed, arguments.dropFirst(2).joined(separator: " "))
                } catch let error as SettingError {
                    return ["\(setting.key) \(error.message)"]
                }
                store.updateSettings(for: directory) { $0 = changed }
                try store.save(to: location)
                let value = setting.shown(changed) ?? ""
                var lines = confirmation(setting, "= \(value)", environment: environment, inSession: inSession)
                let problem = Self.problem(with: resolved(for: directory, store: store, environment: environment))
                if let problem { lines.append("note: \(problem)") }
                return lines
            case "unset":
                guard arguments.count == 2 else { return ["usage: unset <key>"] }
                guard let setting = named(arguments[1]) else { return ["unknown setting \(arguments[1]); /config lists them"] }
                store.updateSettings(for: directory) { setting.unset(&$0) }
                try store.save(to: location)
                return confirmation(setting, "back to its default (\(setting.defaultValue))", environment: environment, inSession: inSession)
            default:
                return ["usage: config [settings] | set <key> <value> | unset <key>"]
            }
        } catch {
            return ["could not update the config: \(error.localizedDescription)"]
        }
    }

    private static func confirmation(_ setting: Setting, _ change: String, environment: [String: String], inSession: Bool) -> [String] {
        let isLive = inSession || setting.takesEffect != .now
        let when = isLive ? setting.takesEffect.rawValue : "in new sessions (a running repl: on /clear, or set it there with /config)"
        var lines = ["\(setting.key) \(change); takes effect \(when)"]
        if let overriding = environment[setting.environmentName] {
            lines.append("note: \(setting.environmentName)=\(overriding) is set in the environment and wins over the saved value")
        }
        return lines
    }

    /// One line per setting: its value and where that comes from.
    static func report(store: AgentConfigStore, directory: URL, location: URL, environment: [String: String]) -> [String] {
        let saved = store.settings(for: directory)
        // Problems were reported when the session started; listing doesn't repeat them.
        let fromEnvironment = fromEnvironment(environment, reportProblems: false)
        let width = all.map(\.key.count).max() ?? 0
        var lines = ["settings for \(directory.path) (saved in \(location.path)):"]
        for setting in all {
            let value: String
            if let shown = setting.shown(fromEnvironment) {
                value = "\(shown) (from \(setting.environmentName))"
            } else if let shown = setting.shown(saved) {
                value = "\(shown) (saved)"
            } else {
                value = "\(setting.defaultValue) (default)"
            }
            let key = setting.key.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(key)  \(value) · \(setting.summary)")
        }
        lines.append("change one with: set <key> <value> · unset <key>")
        return lines
    }
}
