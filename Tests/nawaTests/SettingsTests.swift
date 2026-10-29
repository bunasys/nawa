import AgentCore
import AgentGateway
import Foundation
import Testing
@testable import nawa

@Suite struct SettingsTests {
    private func scratch() throws -> (directory: URL, location: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("config.json"))
    }

    @Test func typedTextBecomesTypedValues() throws {
        #expect(try Settings.parseTokens("120k") == 120_000)
        #expect(try Settings.parseTokens("1.5M") == 1_500_000)
        #expect(throws: SettingError.self) { try Settings.parseTokens("5k") }  // too small to be useful
        #expect(throws: SettingError.self) { try Settings.parseTokens("lots") }
        #expect(try Settings.parsePrice("3, 15") == TokenPrice(inputPerMillion: 3, outputPerMillion: 15))
        #expect(throws: SettingError.self) { try Settings.parsePrice("3") }
        #expect(try Settings.parseOnOff("OFF") == false)
        #expect(throws: SettingError.self) { try Settings.parseOnOff("maybe") }
        #expect(throws: SettingError.self) { try Settings.parsePositiveNumber("0") }
        #expect(try Settings.parsePath("~/journals").hasPrefix("/"))
        #expect(Settings.showPrice(TokenPrice(inputPerMillion: 0.25, outputPerMillion: 2)) == "0.25,2")
    }

    @Test func everyEnvironmentSettingIsCovered() {
        let names = Set(Settings.all.map(\.environmentName))
        #expect(names == [
            "NAWA_COMPACT_AT", "NAWA_HELPER_MODEL", "NAWA_PRICE", "NAWA_HELPER_PRICE", "NAWA_MAX_BUDGET_USD",
            "NAWA_FALLBACK_MODEL", "NAWA_STREAM", "NAWA_SKILLS", "NAWA_PROJECT_SKILLS", "NAWA_SESSIONS",
            "NAWA_SESSIONS_DIR", "NAWA_SESSION_IDLE_MINUTES",
        ])
    }

    @Test func setListAndUnsetRoundTrip() throws {
        let (directory, location) = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let set = Settings.command(["set", "compact_at", "600k"], directory: directory, location: location, environment: [:], inSession: true)
        #expect(set == ["compact_at = 600k; takes effect now"])
        #expect(try AgentConfigStore.load(from: location).settings(for: directory).loop.compactAt == 600_000)

        let list = Settings.command([], directory: directory, location: location, environment: [:])
        #expect(list.contains { $0.contains("compact_at") && $0.contains("600k (saved)") })
        #expect(list.contains { $0.contains("stream") && $0.contains("on (default)") })

        let unset = Settings.command(["unset", "compact_at"], directory: directory, location: location, environment: [:], inSession: true)
        #expect(unset == ["compact_at back to its default (120k); takes effect now"])
        #expect(try AgentConfigStore.load(from: location).settings[AgentConfigStore.key(for: directory)] == nil)
    }

    @Test func mistakesAreExplainedAndNothingIsSaved() throws {
        let (directory, location) = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Settings.command(["set", "stream", "maybe"], directory: directory, location: location, environment: [:]) == ["stream expected on or off, not \"maybe\""])
        #expect(Settings.command(["set", "compact_cap", "1M"], directory: directory, location: location, environment: [:]) == ["unknown setting compact_cap; /config lists them"])
        #expect(Settings.command(["set", "stream"], directory: directory, location: location, environment: [:]) == ["usage: set <key> <value>"])
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }

    @Test func aBudgetWithoutAPriceIsPointedOut() throws {
        let (directory, location) = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lines = Settings.command(["set", "max_budget_usd", "2"], directory: directory, location: location, environment: [:], inSession: true)

        #expect(lines.first == "max_budget_usd = 2; takes effect now")
        #expect(lines.last?.hasPrefix("note: max_budget_usd has no effect without price") == true)
    }

    @Test func fromTheCommandLineAChangeReachesNewSessions() throws {
        let (directory, location) = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lines = Settings.command(["set", "helper_model", "small"], directory: directory, location: location, environment: [:])

        #expect(lines == ["helper_model = small; takes effect in new sessions (a running repl: on /clear, or set it there with /config)"])
    }

    @Test func theEnvironmentWinsOverSavedSettings() throws {
        let directory = URL(fileURLWithPath: "/work/app")
        var store = AgentConfigStore()
        store.updateSettings(for: directory) {
            $0.loop.compactAt = 600_000
            $0.loop.stream = false
            $0.skills = false
        }

        let resolved = Settings.resolved(for: directory, store: store, environment: ["NAWA_STREAM": "1", "NAWA_SKILLS": "nonsense"])

        #expect(resolved.loop.compactAt == 600_000)
        #expect(resolved.loop.stream == true)
        #expect(resolved.skills == false)  // a value that doesn't parse is ignored, not applied
        let lines = Settings.report(store: store, directory: directory, location: URL(fileURLWithPath: "/c.json"), environment: ["NAWA_STREAM": "1"])
        #expect(lines.contains { $0.contains("stream") && $0.contains("on (from NAWA_STREAM)") })
    }

    @Test func sessionRecordingFollowsItsSettings() {
        #expect(AgentCLI.sessionStore(DirectorySettings(sessions: false)) == nil)
        #expect(AgentCLI.sessionStore(DirectorySettings(sessionsDirectory: "/j"))?.directory.path == "/j")
        // The variables were already read into the settings; they don't decide twice.
        #expect(AgentCLI.sessionStore(DirectorySettings(), environment: ["NAWA_SESSIONS": "off", "XDG_STATE_HOME": "/s"])?.directory.path == "/s/nawa/sessions")
        #expect(AgentCLI.idleSessionTimeout(minutes: nil) == .seconds(1800))
        #expect(AgentCLI.idleSessionTimeout(minutes: 5) == .seconds(300))
    }

    @Test func configFilesWithoutSettingsStillLoad() throws {
        let (directory, location) = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"version": 1, "directories": {}}"#.write(to: location, atomically: true, encoding: .utf8)

        let store = try AgentConfigStore.load(from: location)

        #expect(store.settings.isEmpty)
    }
}
