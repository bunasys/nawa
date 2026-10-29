import AgentCore
@testable import AgentGateway
import Foundation
import Testing

struct AgentConfigStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func provider(_ name: String, model: String? = nil) -> ProviderConfig {
        ProviderConfig(name: name, baseURL: URL(string: "https://\(name).example.com/v1")!, apiKey: "k", model: model)
    }

    @Test
    func defaultLocationHonoursExplicitFileThenXDGThenHome() {
        let explicit = AgentConfigStore.defaultLocation(environment: ["NAWA_CONFIG_FILE": "/tmp/x.json", "XDG_CONFIG_HOME": "/xdg"])
        #expect(explicit.path == "/tmp/x.json")

        let xdg = AgentConfigStore.defaultLocation(environment: ["XDG_CONFIG_HOME": "/xdg"])
        #expect(xdg.path == "/xdg/nawa/config.json")

        let home = AgentConfigStore.defaultLocation(environment: [:])
        #expect(home.path.hasSuffix("/.config/nawa/config.json"))
    }

    @Test
    func loadOfMissingFileIsEmpty() throws {
        let file = try temporaryDirectory().appendingPathComponent("config.json")
        let store = try AgentConfigStore.load(from: file)
        #expect(store.directories.isEmpty)
        #expect(store.version == AgentConfigStore.currentVersion)
    }

    @Test
    func loadOfMalformedFileThrows() throws {
        let file = try temporaryDirectory().appendingPathComponent("config.json")
        try Data("{not json".utf8).write(to: file)
        #expect(throws: AgentConfigStoreError.self) { try AgentConfigStore.load(from: file) }
    }

    @Test
    func loadOfNewerVersionThrows() throws {
        let file = try temporaryDirectory().appendingPathComponent("config.json")
        try Data(#"{"version": 99, "directories": {}}"#.utf8).write(to: file)
        #expect(throws: AgentConfigStoreError.self) { try AgentConfigStore.load(from: file) }
    }

    @Test
    func addProviderScopesByDirectoryAndActivates() throws {
        let dirA = try temporaryDirectory()
        let dirB = try temporaryDirectory()
        var store = AgentConfigStore()

        store.addProvider(provider("openai", model: "gpt-4o-mini"), for: dirA)
        store.addProvider(provider("ollama", model: "llama3.2"), for: dirA)
        store.addProvider(provider("vllm"), for: dirB)

        let a = try #require(store.gatewayConfig(for: dirA))
        #expect(a.providers.map(\.name) == ["openai", "ollama"])
        #expect(a.activeProvider == "ollama")

        let b = try #require(store.gatewayConfig(for: dirB))
        #expect(b.providers.map(\.name) == ["vllm"])
        #expect(b.activeProvider == "vllm")
    }

    @Test
    func addProviderWithSameNameReplaces() throws {
        let dir = try temporaryDirectory()
        var store = AgentConfigStore()
        store.addProvider(provider("openai", model: "gpt-4o-mini"), for: dir)
        store.addProvider(provider("openai", model: "gpt-4.1"), for: dir)

        let config = try #require(store.gatewayConfig(for: dir))
        #expect(config.providers.count == 1)
        #expect(config.providers[0].model == "gpt-4.1")
    }

    @Test
    func addWithoutActivateKeepsExistingActive() throws {
        let dir = try temporaryDirectory()
        var store = AgentConfigStore()
        store.addProvider(provider("first"), for: dir)
        store.addProvider(provider("second"), for: dir, activate: false)
        #expect(store.gatewayConfig(for: dir)?.activeProvider == "first")
    }

    @Test
    func activateAndRemoveProvider() throws {
        let dir = try temporaryDirectory()
        var store = AgentConfigStore()
        store.addProvider(provider("a"), for: dir)
        store.addProvider(provider("b"), for: dir)

        try store.activateProvider(named: "a", for: dir)
        #expect(store.gatewayConfig(for: dir)?.activeProvider == "a")
        #expect(throws: AgentConfigStoreError.self) { try store.activateProvider(named: "zzz", for: dir) }

        try store.removeProvider(named: "a", for: dir)
        #expect(store.gatewayConfig(for: dir)?.activeProvider == "b")

        try store.removeProvider(named: "b", for: dir)
        #expect(store.gatewayConfig(for: dir) == nil)
    }

    @Test
    func directoryKeyIsStandardized() throws {
        let dir = try temporaryDirectory()
        let messy = dir.appendingPathComponent("sub").appendingPathComponent("..")
        #expect(AgentConfigStore.key(for: messy) == AgentConfigStore.key(for: dir))
    }

    @Test
    func saveThenLoadRoundTripsWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("nested").appendingPathComponent("config.json")
        let dir = try temporaryDirectory()

        var store = AgentConfigStore()
        store.addProvider(provider("openai", model: "gpt-4o-mini"), for: dir)
        try store.save(to: file)

        let loaded = try AgentConfigStore.load(from: file)
        #expect(loaded == store)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o777 == 0o600)

        // The saved gateway config is directly usable.
        let gateway = try #require(loaded.gatewayConfig(for: dir)).makeGateway()
        #expect(gateway.activeProvider?.model == "gpt-4o-mini")
    }
}

@Suite struct DirectorySettingsTests {
    /// The file keeps the loop's fields beside the CLI's, under the contract's names.
    @Test func savesFlatSnakeCaseFields() throws {
        let settings = DirectorySettings(
            loop: LoopSettings(compactAt: 600_000, price: TokenPrice(inputPerMillion: 3, outputPerMillion: 15), stream: false),
            skills: false,
            sessionsDirectory: "/j"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)

        #expect(json == #"{"compact_at":600000,"price":{"input_per_million":3,"output_per_million":15},"sessions_dir":"\/j","skills":false,"stream":false}"#)
        #expect(try JSONDecoder().decode(DirectorySettings.self, from: Data(json.utf8)) == settings)
    }

    @Test func laterSettingsWinFieldByField() {
        let saved = DirectorySettings(loop: LoopSettings(compactAt: 1, helperModel: "a"), skills: true)
        let environment = DirectorySettings(loop: LoopSettings(helperModel: "b"), sessions: false)

        let merged = saved.overlaid(by: environment)

        #expect(merged == DirectorySettings(loop: LoopSettings(compactAt: 1, helperModel: "b"), skills: true, sessions: false))
    }

    @Test func aDirectoryWithNothingSetLeavesTheFile() {
        let directory = URL(fileURLWithPath: "/p")
        var store = AgentConfigStore()
        store.updateSettings(for: directory) { $0.skills = false }
        #expect(store.settings.count == 1)

        store.updateSettings(for: directory) { $0.skills = nil }

        #expect(store.settings.isEmpty)
    }
}
