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

        do {
            for try await line in Self.inputLines() {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                // Handled in arrival order: `session/new` must finish before the
                // `session/prompt` that names its session. A prompt only starts
                // its turn, so a later `session/cancel` is not blocked behind it.
                await connection.handle(text: line)
            }
        } catch {
            await connection.finishOutbound()
            await writer.value
            throw error
        }
        // stdin closed: write the replies already queued, then stop.
        await connection.finishOutbound()
        await writer.value
    }

    /// stdin, line by line. Apple's Foundation has `FileHandle.bytes`;
    /// Linux Foundation does not, so there `InputLines` reads it.
    private static func inputLines() -> some AsyncSequence<String, any Error> {
        #if canImport(Darwin)
        FileHandle.standardInput.bytes.lines
        #else
        InputLines(FileHandle.standardInput)
        #endif
    }
}

/// The lines read from a file handle, without their `\n` / `\r\n`, ending
/// when it reaches end of file. Built on `DispatchIO`, which reports end of
/// file explicitly (Linux Foundation's `readabilityHandler` can miss it when
/// it arrives together with the last data); used for stdin on Linux and
/// tested everywhere.
struct InputLines: AsyncSequence, Sendable {
    typealias Element = String

    private let lines: AsyncThrowingStream<String, any Error>

    init(_ handle: FileHandle) {
        let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        self.lines = lines
        let queue = DispatchQueue(label: "nawa.input-lines")
        // The handle owns the descriptor: keep it alive until the channel is done.
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            _ = handle
        }
        channel.setLimit(lowWater: 1)
        // Read handlers run one at a time on `queue`, so `pending` needs no lock.
        nonisolated(unsafe) var pending = Data()
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty {
                pending.append(contentsOf: data)
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    continuation.yield(Self.text(pending[start..<newline]))
                    start = pending.index(after: newline)
                }
                pending = Data(pending[start...])
            }
            guard done else { return }
            if error != 0, error != ECANCELED {
                continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
            } else {
                if !pending.isEmpty { continuation.yield(Self.text(pending)) }
                continuation.finish()
            }
            channel.close()
        }
        continuation.onTermination = { _ in channel.close(flags: .stop) }
    }

    private static func text(_ line: Data) -> String {
        var line = line
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }

    func makeAsyncIterator() -> AsyncThrowingStream<String, any Error>.AsyncIterator {
        lines.makeAsyncIterator()
    }
}
