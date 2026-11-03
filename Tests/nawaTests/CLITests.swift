import AgentCore
@testable import AgentGateway
import AgentMCP
import Foundation
import Testing
@testable import nawa

@Suite struct CLITests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// No URL, no saved config, no Gateways.json: only the environment decides.
    private func bareEnvironment(_ directory: URL, _ extra: [String: String]) -> [String: String] {
        var environment = ["NAWA_CONFIG_FILE": directory.appendingPathComponent("config.json").path]
        environment.merge(extra) { _, new in new }
        return environment
    }

    @Test func anAnthropicKeyGoesToAnthropicsEndpoint() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = bareEnvironment(directory, ["NAWA_GATEWAY_API": "anthropic", "ANTHROPIC_API_KEY": "sk-ant-test"])

        let config = try AgentCLI.gatewayConfig(directory: directory, environment: environment)

        #expect(config.providers.first?.api == .anthropic)
        #expect(config.providers.first?.baseURL.host == "api.anthropic.com")
        #expect(config.providers.first?.apiKey == "sk-ant-test")
    }

    @Test func withoutAnAPIItIsOpenAI() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = try AgentCLI.gatewayConfig(directory: directory, environment: bareEnvironment(directory, [:]))

        #expect(config.providers.first?.baseURL.absoluteString == "https://api.openai.com/v1")
    }

    @Test func gatewaysJSONIsReadFromTheSessionsDirectory() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = #"{"activeProvider": "local", "providers": [{"name": "local", "baseURL": "http://localhost:11434/v1"}]}"#
        try Data(file.utf8).write(to: directory.appendingPathComponent("Gateways.json"))

        let config = try AgentCLI.gatewayConfig(directory: directory, environment: bareEnvironment(directory, [:]))

        #expect(config.activeProvider == "local")
    }

    @Test func sessionsInOneDirectoryShareAGatewayUntilItsConfigChanges() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("config.json")
        let cache = GatewayCache(environment: bareEnvironment(directory, [:]))
        let local = ProviderConfig(name: "local", baseURL: URL(string: "http://localhost:11434/v1")!)
        try AgentConfigStore.modify(at: location) { $0.addProvider(local, for: directory) }

        let first = try cache.gateway(for: directory)
        let second = try cache.gateway(for: directory)
        #expect(first.failover === second.failover)

        let other = ProviderConfig(name: "other", baseURL: URL(string: "http://localhost:8000/v1")!)
        try AgentConfigStore.modify(at: location) { $0.addProvider(other, for: directory) }
        let changed = try cache.gateway(for: directory)
        #expect(changed.failover !== first.failover)
        #expect(changed.activeProviderName == "other")
    }

    @Test func mcpToolNamesStayWithinWhatProvidersAccept() {
        #expect(PrefixedTool.prefix(forServer: "my server/ü") == "my_server____")
        #expect(PrefixedTool.prefix(forServer: "git-hub_2") == "git-hub_2__")

        let longServer = PrefixedTool.prefix(forServer: String(repeating: "s", count: 100))
        let tool = MCPToolDefinition(name: String(repeating: "t", count: 100))
        let name = PrefixedTool(prefix: longServer, wrapped: MCPClient(config: MCPServerConfig(name: "x", command: "/bin/false")), remote: tool).definition.name
        #expect(name.count == 64)
        #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    @Test func aOneShotKeepsTheDirectorysSettings() {
        let settings = LoopSettings(price: TokenPrice(inputPerMillion: 3, outputPerMillion: 15), fallbackModel: "backup", stream: true)

        let options = WakuCompatibility.oneShotOptions(settings: settings)

        #expect(options.fallbackModel == "backup")
        #expect(options.pricing != nil)
        #expect(options.maxTurns == 1)
        #expect(!options.sendTools)
        #expect(!options.streamReplies)
    }

    @Test func pruningEverythingIsNotAnAge() {
        #expect(SessionsCommand.parseAge("0h") == nil)
        #expect(SessionsCommand.parseAge("1h") == 3600)
    }

    @Test func mistakesExitWithStatusTwoOnStderr() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "NAWA_CONFIG_FILE": directory.appendingPathComponent("config.json").path,
            "NAWA_SESSIONS": "off",
            "PATH": "/usr/bin:/bin",
        ]

        let mistakes = [
            ["bogus"], ["config", "use"], ["config", "set", "stream", "maybe"], ["provider"],
            ["serve", "--token", "s3cret"], ["serve", "--port", "http"], ["connect"], ["connect", "devbox:7878"],
        ]
        for arguments in mistakes {
            let run = try runNawa(arguments, in: directory, environment: environment)
            #expect(run.status == 2, "nawa \(arguments.joined(separator: " "))")
            #expect(run.stdout.isEmpty, "nawa \(arguments.joined(separator: " "))")
            #expect(run.stderr.hasPrefix("nawa: "), "nawa \(arguments.joined(separator: " "))")
        }
        let help = try runNawa(["help"], in: directory, environment: environment)
        #expect(help.status == 0)
        #expect(help.stdout.hasPrefix("Usage: nawa"))
    }

    private func runNawa(_ arguments: [String], in directory: URL, environment: [String: String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try nawaBinary()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// The executable `swift build --build-tests` puts next to the test bundle.
    private func nawaBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for configuration in ["debug", "release"] {
            let candidate = root.appendingPathComponent(".build/\(configuration)/nawa")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
