import AgentCore
import AgentMCP
import Foundation
import Testing

/// Runs `MCPClient` against tiny MCP servers written in `sh`: each one
/// answers `initialize` (id 1) and `tools/list` (id 2), reads the
/// `tools/call` (id 3), then does what the test needs.
@Suite(.timeLimit(.minutes(1)))
struct MCPClientTests {
    @Test
    func errorResponseFailsTheCallWithTheServersMessage() async throws {
        let client = try await startedClient(afterToolCall: """
        printf '{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"disk full"}}\\n'
        cat >/dev/null
        """)
        defer { Task { await client.stop() } }
        await #expect {
            _ = try await client.callTool(name: "echo", arguments: .object([:]))
        } throws: { error in
            String(describing: error).contains("disk full")
        }
    }

    @Test
    func serverExitFailsThePendingCall() async throws {
        let client = try await startedClient(afterToolCall: "exit 0")
        await #expect(throws: MCPClientError.self) {
            _ = try await client.callTool(name: "echo", arguments: .object([:]))
        }
    }

    /// The server's `ping` reuses the id of our pending call: it must be
    /// answered, and must not resolve our call.
    @Test
    func serverPingIsAnsweredAndNotTakenForTheReply() async throws {
        let client = try await startedClient(afterToolCall: """
        printf '{"jsonrpc":"2.0","id":3,"method":"ping"}\\n'
        read reply
        case "$reply" in
          *'"id":3'*'"result":{}'*) answer=pong ;;
          *) answer=no-pong ;;
        esac
        printf '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"%s"}]}}\\n' "$answer"
        cat >/dev/null
        """)
        defer { Task { await client.stop() } }
        let output = try await client.callTool(name: "echo", arguments: .object([:]))
        #expect(output == "pong")
    }

    @Test
    func silentServerTimesOut() async throws {
        let client = try await startedClient(afterToolCall: "cat >/dev/null", toolCallTimeout: 0.3)
        defer { Task { await client.stop() } }
        await #expect {
            _ = try await client.callTool(name: "echo", arguments: .object([:]))
        } throws: { error in
            guard case MCPClientError.timedOut = error else { return false }
            return true
        }
    }

    @Test
    func cancellingTheCallerEndsTheCall() async throws {
        let client = try await startedClient(afterToolCall: "cat >/dev/null")
        defer { Task { await client.stop() } }
        let call = Task { try await client.callTool(name: "echo", arguments: .object([:])) }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await call.value
        }
    }

    /// `sh` is a bare name found on `PATH`; the marker file is only visible
    /// from the configured working directory.
    @Test
    func bareCommandRunsFromTheWorkingDirectory() async throws {
        let directory = try temporaryDirectory()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("marker").path, contents: Data())
        let script = try writeScript("""
        read line
        printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
        read line
        read line
        if [ -f marker ]; then name=inside; else name=outside; fi
        printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"%s"}]}}\\n' "$name"
        cat >/dev/null
        """)
        let client = MCPClient(config: MCPServerConfig(name: "test", command: "sh", args: [script.path], workingDirectory: directory.path))
        try await client.start()
        defer { Task { await client.stop() } }
        #expect(await client.tools.map(\.name) == ["inside"])
    }

    @Test
    func unknownCommandIsReported() async {
        let client = MCPClient(config: MCPServerConfig(name: "test", command: "no-such-mcp-server-xyz"))
        await #expect(throws: MCPClientError.self) {
            try await client.start()
        }
    }

    // MARK: - Helpers

    private func startedClient(afterToolCall behaviour: String, toolCallTimeout: Double? = nil) async throws -> MCPClient {
        let script = try writeScript("""
        read line
        printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
        read line
        read line
        printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo"}]}}\\n'
        read line
        \(behaviour)
        """)
        let config = MCPServerConfig(name: "test", command: "sh", args: [script.path], toolCallTimeout: toolCallTimeout)
        let client = MCPClient(config: config)
        try await client.start()
        return client
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeScript(_ body: String) throws -> URL {
        let script = try temporaryDirectory().appendingPathComponent("server.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        return script
    }
}
