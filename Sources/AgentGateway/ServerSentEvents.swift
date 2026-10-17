/// Reading the `data:` lines of a `text/event-stream` body, shared by the
/// streaming clients.
///
/// Each `data:` line is handed over on its own (OpenAI and Anthropic both
/// put one JSON object per line); `event:`, `id:`, comments and blank
/// lines are skipped. A line longer than `maxLineBytes` fails the stream
/// rather than growing without bound on a broken server.
enum ServerSentEvents {
    static let maxLineBytes = 1 << 20

    static func forEachData<Bytes: AsyncSequence>(
        in bytes: Bytes,
        _ body: (String) throws -> Void
    ) async throws where Bytes.Element == UInt8 {
        var line: [UInt8] = []
        func flush() throws {
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            defer { line.removeAll(keepingCapacity: true) }
            guard line.starts(with: Array("data:".utf8)) else { return }
            var payload = line.dropFirst(5)
            if payload.first == UInt8(ascii: " ") { payload = payload.dropFirst() }
            guard !payload.isEmpty else { return }
            try body(String(decoding: payload, as: UTF8.self))
        }
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                try flush()
            } else {
                line.append(byte)
                if line.count > maxLineBytes {
                    throw GatewayError.invalidResponse("a server-sent event line is over \(maxLineBytes) bytes")
                }
            }
        }
        try flush()
    }
}
