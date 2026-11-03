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
    /// Parses typed text into its field; throws `SettingError` for text it
    /// can't use. A relative path is taken relative to the given directory.
    let set: (inout DirectorySettings, String, URL) throws -> Void
    let unset: (inout DirectorySettings) -> Void
    /// The field's value as `/config` shows it, or nil when it isn't set.
    let shown: (DirectorySettings) -> String?

    /// A setting for one optional field: `parse` turns typed text into its
    /// value, `show` turns the value back into text.
    init<Value>(
        _ key: String,
        _ environmentName: String,
        field: WritableKeyPath<DirectorySettings, Value?>,
        parse: @escaping (String, _ directory: URL) throws -> Value,
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
        self.set = { settings, text, directory in settings[keyPath: field] = try parse(text, directory) }
        self.unset = { settings in settings[keyPath: field] = nil }
        self.shown = { settings in settings[keyPath: field].map(show) }
    }

    /// The same for a value that means the same wherever it is set.
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
        self.init(key, environmentName, field: field, parse: { text, _ in try parse(text) }, show: show,
                  defaultValue: defaultValue, takesEffect: takesEffect, summary: summary)
    }
}

struct SettingError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
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
            Setting("effort", "NAWA_EFFORT", field: \.loop.effort, parse: parseEffort, show: { $0 },
                    defaultValue: "the provider's", takesEffect: .now,
                    summary: "how hard the model thinks: low, medium, high, … (words depend on the provider)"),
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
            Setting("sessions_dir", "NAWA_SESSIONS_DIR", field: \.sessionsDirectory, parse: parsePath(_:relativeTo:), show: { $0 },
                    defaultValue: "~/.local/state/nawa/sessions", takesEffect: .nextStart,
                    summary: "where session journals are written"),
            Setting("session_idle_minutes", "NAWA_SESSION_IDLE_MINUTES", field: \.sessionIdleMinutes, parse: parseIdleMinutes, show: showNumber,
                    defaultValue: "30", takesEffect: .nextStart,
                    summary: "serve: unload a session after this long without a prompt"),
        ]
    }

    static func named(_ key: String) -> Setting? {
        all.first { $0.key == key.lowercased() }
    }

    // MARK: What a session runs with

    /// `directory`'s saved settings, with any set environment variable
    /// winning over its saved value. Silent: a variable that doesn't parse
    /// is left out, and `environmentProblems` says so once at startup.
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

    /// The settings the environment variables give; values that don't parse are left out.
    static func fromEnvironment(_ environment: [String: String]) -> DirectorySettings {
        readEnvironment(environment).settings
    }

    /// One line per environment variable that doesn't parse. Said once, at
    /// startup: settings are resolved again for every session and every
    /// `/clear`, where a line on stderr would land in the middle of the
    /// repl's screen.
    static func environmentProblems(_ environment: [String: String]) -> [String] {
        readEnvironment(environment).problems
    }

    private static func readEnvironment(_ environment: [String: String]) -> (settings: DirectorySettings, problems: [String]) {
        // A relative path in a variable means one relative to where nawa runs.
        let processDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var settings = DirectorySettings()
        var problems: [String] = []
        for setting in all {
            guard let text = environment[setting.environmentName] else { continue }
            do {
                try setting.set(&settings, text, processDirectory)
            } catch {
                let message = (error as? SettingError)?.message ?? "\(error)"
                problems.append("ignoring \(setting.environmentName)=\(text): \(message)")
            }
        }
        return (settings, problems)
    }

    /// A combination of settings that doesn't work, said once: at startup
    /// and after a `/config` change, never while a turn draws.
    static func problem(with settings: DirectorySettings) -> String? {
        guard settings.loop.maxBudgetUSD != nil, settings.loop.price == nil else { return nil }
        return "max_budget_usd has no effect without price (set price to \"input,output\" USD per million tokens)"
    }

    // MARK: Typed text

    /// The largest token count a setting takes: far past any model's
    /// window, and small enough that converting it to `Int` can't trap.
    static let maxTokens = 100_000_000

    /// `120000`, `120k`, `1.5M` (any case), from 10k to 100M.
    static func parseTokens(_ text: String) throws -> Int {
        guard let tokens = tokenCount(text), tokens >= 10_000, tokens <= maxTokens else {
            throw SettingError(message: "expected a token count from 10k to 100M, like 120k or 1.5M, not \"\(text)\"")
        }
        return tokens
    }

    static func tokenCount(_ text: String) -> Int? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        let multipliers: [(suffix: String, factor: Double)] = [("k", 1_000), ("m", 1_000_000)]
        for (suffix, factor) in multipliers where lower.hasSuffix(suffix) {
            guard let number = Double(lower.dropLast()), number > 0 else { return nil }
            // `Int(_:)` traps on infinity and past `Int.max` ("infk", "1e20k").
            let tokens = (number * factor).rounded()
            guard tokens <= Double(maxTokens) else { return nil }
            return Int(exactly: tokens)
        }
        return Int(lower)
    }

    /// `"3,15"`: input and output USD per million tokens.
    static func parsePrice(_ text: String) throws -> TokenPrice {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let expected = SettingError(message: "expected \"input,output\" USD per million tokens, like 3,15, not \"\(text)\"")
        guard parts.count == 2, let input = parts[0], let output = parts[1] else { throw expected }
        let isUsable = input.isFinite && output.isFinite && input >= 0 && output >= 0
        guard isUsable else { throw expected }
        return TokenPrice(inputPerMillion: input, outputPerMillion: output)
    }

    static func showPrice(_ price: TokenPrice) -> String {
        "\(showNumber(price.inputPerMillion)),\(showNumber(price.outputPerMillion))"
    }

    static func parsePositiveNumber(_ text: String) throws -> Double {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite, number > 0 else {
            throw SettingError(message: "expected a positive number, not \"\(text)\"")
        }
        return number
    }

    /// A year: longer is no different from never, and far longer overflows `Duration`.
    static let maxIdleMinutes: Double = 365 * 24 * 60

    static func parseIdleMinutes(_ text: String) throws -> Double {
        let minutes = try parsePositiveNumber(text)
        guard minutes <= maxIdleMinutes else {
            throw SettingError(message: "expected at most \(showNumber(maxIdleMinutes)) minutes (a year), not \"\(text)\"")
        }
        return minutes
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

    /// One word, lowercased: providers take effort levels as lowercase
    /// words, and a typo with a space in it is never one.
    static func parseEffort(_ text: String) throws -> String {
        let word = try parseText(text).lowercased()
        let isOneWord = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard isOneWord else { throw SettingError(message: "expected one word, like low, medium or high") }
        return word
    }

    static func parseText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw SettingError(message: "expected a value") }
        return trimmed
    }

    /// `~/journals`, or a path relative to `directory`: saved absolute, so
    /// it means the same wherever nawa starts later.
    static func parsePath(_ text: String, relativeTo directory: URL) throws -> String {
        let expanded = (try parseText(text) as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return directory.appendingPathComponent(expanded).standardizedFileURL.path
    }

    // MARK: The command

    /// `/config` and `nawa config settings|set|unset`, given the words after
    /// the command. Returns the lines to show; throws `UsageError` for
    /// words it can't use, and the store's error when it can't be read or
    /// written. Saves to the store at `location`; the caller applies what
    /// takes effect now. `inSession` is true for `/config`, whose session
    /// applies changes at once; from the command line they reach new
    /// sessions only.
    static func command(
        _ arguments: [String],
        directory: URL,
        location: URL = AgentConfigStore.defaultLocation(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inSession: Bool = false
    ) throws -> [String] {
        switch arguments.first?.lowercased() {
        case nil, "settings", "list":
            let store = try AgentConfigStore.load(from: location)
            return report(store: store, directory: directory, location: location, environment: environment)
        case "set":
            guard arguments.count >= 3 else { throw UsageError("usage: set <key> <value>") }
            let setting = try existingSetting(arguments[1])
            let text = arguments.dropFirst(2).joined(separator: " ")
            let store = try AgentConfigStore.modify(at: location) { store in
                var changed = store.settings(for: directory)
                do {
                    try setting.set(&changed, text, directory)
                } catch let error as SettingError {
                    throw UsageError("\(setting.key) \(error.message)")
                }
                store.updateSettings(for: directory) { $0 = changed }
                return store
            }
            let value = setting.shown(store.settings(for: directory)) ?? ""
            var lines = confirmation(setting, "= \(value)", environment: environment, inSession: inSession)
            let problem = Self.problem(with: resolved(for: directory, store: store, environment: environment))
            if let problem { lines.append("note: \(problem)") }
            return lines
        case "get":
            guard arguments.count == 2 else { throw UsageError("usage: get <key>") }
            let setting = try existingSetting(arguments[1])
            let store = try AgentConfigStore.load(from: location)
            let value = describe(setting, saved: store.settings(for: directory), fromEnvironment: fromEnvironment(environment))
            return ["\(setting.key): \(value) · \(setting.summary)"]
        case "unset":
            guard arguments.count == 2 else { throw UsageError("usage: unset <key>") }
            let setting = try existingSetting(arguments[1])
            try AgentConfigStore.modify(at: location) { store in
                store.updateSettings(for: directory) { setting.unset(&$0) }
            }
            return confirmation(setting, "back to its default (\(setting.defaultValue))", environment: environment, inSession: inSession)
        default:
            throw UsageError("usage: config [settings] | get <key> | set <key> <value> | unset <key>")
        }
    }

    private static func existingSetting(_ key: String) throws -> Setting {
        guard let setting = named(key) else { throw UsageError("unknown setting \(key); /config lists them") }
        return setting
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
        let fromEnvironment = fromEnvironment(environment)
        let width = all.map(\.key.count).max() ?? 0
        var lines = ["settings for \(directory.path) (saved in \(location.path)):"]
        for setting in all {
            let value = describe(setting, saved: saved, fromEnvironment: fromEnvironment)
            let key = setting.key.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(key)  \(value) · \(setting.summary)")
        }
        lines.append("change one with: set <key> <value> · unset <key>")
        return lines
    }

    /// A setting's value and where it comes from: the environment wins over
    /// the saved value, which wins over the default.
    private static func describe(_ setting: Setting, saved: DirectorySettings, fromEnvironment: DirectorySettings) -> String {
        if let shown = setting.shown(fromEnvironment) { return "\(shown) (from \(setting.environmentName))" }
        if let shown = setting.shown(saved) { return "\(shown) (saved)" }
        return "\(setting.defaultValue) (default)"
    }
}
