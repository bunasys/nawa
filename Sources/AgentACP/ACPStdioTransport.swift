import AgentCore
import AgentJSONRPC
import Foundation

/// ACP over stdio: newline-delimited JSON-RPC on stdin/stdout, the transport
/// editors and desktop clients (Zed, Waku, …) use when they launch the agent
/// as a subprocess.
///
/// One process serves one connection. Every outbound message — responses and
/// `session/update` notifications alike — is written to stdout, so nothing
/// else in the process may print there; diagnostics belong on stderr.
public struct ACPStdioTransport: Sendable {
    public let factory: any ACPSessionFactory
    public let info: ACPServerInfo
    public let capabilities: ACPCapabilities

    public init(
        factory: any ACPSessionFactory,
        info: ACPServerInfo = .nawa,
        capabilities: ACPCapabilities = .init()
    ) {
        self.factory = factory
        self.info = info
        self.capabilities = capabilities
    }

    /// Serve until stdin closes.
    public func run() async throws {
        let connection = ACPConnection(
            connectionID: "stdio",
            factory: factory,
            info: info,
            capabilities: capabilities,
            routing: .singleStream
        )

        let writer = Task {
            for await message in await connection.outbound {
                let line = message.json.description + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
        defer { writer.cancel() }

        for try await line in FileHandle.standardInput.bytes.lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let message = try? parseJSONRPCLine(line) else {
                FileHandle.standardError.write(Data("nawa acp: ignoring unparseable line\n".utf8))
                continue
            }
            // Handled in arrival order: `session/new` must finish before the
            // `session/prompt` that names its session. A prompt only starts
            // its turn, so a later `session/cancel` is not blocked behind it.
            await connection.handle(message)
        }
    }
}
