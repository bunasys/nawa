import Foundation
import Testing
@testable import nawa

@Suite struct RemoteAccessTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func loopbackWithoutATokenIsTodaysOpenLocalServer() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }

        let options = try RemoteAccess.serveOptions(arguments: [], environment: [:], stateDirectory: state)

        #expect(options == .init(host: "127.0.0.1", port: 7878, token: nil, tokenSource: nil))
        #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("serve-token").path))
    }

    @Test func anOpenAddressGetsATokenFileMadeOnceAndKept() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        let tokenFile = state.appendingPathComponent("nawa/serve-token")

        let first = try RemoteAccess.serveOptions(arguments: ["--host", "0.0.0.0", "--port", "9000"], environment: [:], stateDirectory: state.appendingPathComponent("nawa"))
        let second = try RemoteAccess.serveOptions(arguments: ["--host", "0.0.0.0"], environment: [:], stateDirectory: state.appendingPathComponent("nawa"))

        #expect(first.port == 9000)
        #expect(first.tokenSource == tokenFile.path)
        #expect(first.token?.count == 64)
        #expect(second.token == first.token)
        let mode = try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(RemoteAccess.warning(for: first) != nil)
    }

    @Test func aTokenFileOthersCanReadIsRefused() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        let tokenFile = state.appendingPathComponent("serve-token")
        try Data("s3cret\n".utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)

        #expect(throws: RemoteAccess.TokenFileError.self) {
            try RemoteAccess.serveOptions(arguments: ["--host", "0.0.0.0"], environment: [:], stateDirectory: state)
        }
    }

    @Test func aTokenComesFromTheEnvironmentOrAFileNeverTheCommandLine() throws {
        let state = try scratch()
        defer { try? FileManager.default.removeItem(at: state) }
        let tokenFile = state.appendingPathComponent("my-token")
        try Data("from-file\n".utf8).write(to: tokenFile)

        let fromEnvironment = try RemoteAccess.serveOptions(arguments: ["--token", "env:MY_TOKEN"], environment: ["MY_TOKEN": "from-env"], stateDirectory: state)
        let fromFile = try RemoteAccess.serveOptions(arguments: ["--host", "::", "--token", "file:\(tokenFile.path)"], environment: [:], stateDirectory: state)

        #expect(fromEnvironment.token == "from-env")
        #expect(fromEnvironment.tokenSource == "$MY_TOKEN")
        #expect(fromFile.token == "from-file")
        #expect(throws: UsageError.self) { try RemoteAccess.serveOptions(arguments: ["--token", "s3cret"], environment: [:], stateDirectory: state) }
        #expect(throws: UsageError.self) { try RemoteAccess.serveOptions(arguments: ["--token", "env:UNSET"], environment: [:], stateDirectory: state) }
        #expect(throws: UsageError.self) { try RemoteAccess.serveOptions(arguments: ["--port", "70000"], environment: [:], stateDirectory: state) }
        #expect(throws: UsageError.self) { try RemoteAccess.serveOptions(arguments: ["--host"], environment: [:], stateDirectory: state) }
    }

    @Test func connectTakesTheTokenFromItsFlagOrNAWA_SERVE_TOKEN() throws {
        let fromVariable = try RemoteAccess.connectBridge(arguments: ["https://devbox.example"], environment: ["NAWA_SERVE_TOKEN": "t1"])
        let fromFlag = try RemoteAccess.connectBridge(arguments: ["ws://devbox:7878/acp", "--token", "env:OTHER"], environment: ["NAWA_SERVE_TOKEN": "t1", "OTHER": "t2"])
        let without = try RemoteAccess.connectBridge(arguments: ["ws://localhost:7878"], environment: [:])

        #expect(fromVariable.url == "wss://devbox.example/acp")
        #expect(fromVariable.token == "t1")
        #expect(fromFlag.token == "t2")
        #expect(without.token == nil)
        #expect(throws: UsageError.self) { try RemoteAccess.connectBridge(arguments: ["ws://devbox", "--token", "t3"], environment: [:]) }
    }

    @Test func onlyLoopbackNamesCountAsLocal() {
        #expect(RemoteAccess.isLoopback("127.0.0.1"))
        #expect(RemoteAccess.isLoopback("localhost"))
        #expect(RemoteAccess.isLoopback("::1"))
        #expect(!RemoteAccess.isLoopback("0.0.0.0"))
        #expect(!RemoteAccess.isLoopback("::"))
        #expect(!RemoteAccess.isLoopback("devbox.lan"))
        #expect(RemoteAccess.authority(host: "::", port: 7878) == "[::]:7878")
    }
}
