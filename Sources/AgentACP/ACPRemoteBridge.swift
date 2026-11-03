import AgentJSONRPC
import Foundation
import HummingbirdWSClient
import Logging
import Synchronization

/// `nawa connect`: ACP over stdio on one side, a remote `nawa serve` over
/// WebSocket on the other. Editors (Zed, …) only launch a local command and
/// speak stdio to it; this lets them use an agent on another machine.
///
/// Each stdin line is sent as one text frame and each text frame received is
/// written as one line: the server's WebSocket transport carries one JSON-RPC
/// message per frame, the same messages `nawa acp` reads and writes as lines.
public struct ACPRemoteBridge: Sendable {
    /// The server's `ws://` or `wss://` URL.
    public let url: String
    /// Sent as `Authorization: Bearer <token>` on the upgrade request.
    public let token: String?

    /// Nil when `address` is not a ws, wss, http or https URL. http(s)
    /// becomes ws(s), and a URL without a path gets the server's `/acp`.
    public init?(address: String, token: String?) {
        guard var components = URLComponents(string: address), components.host != nil else { return nil }
        let schemes = ["ws": "ws", "wss": "wss", "http": "ws", "https": "wss"]
        guard let scheme = schemes[components.scheme?.lowercased() ?? ""] else { return nil }
        components.scheme = scheme
        if components.path.isEmpty || components.path == "/" { components.path = "/acp" }
        guard let url = components.string else { return nil }
        self.url = url
        self.token = token
    }

    /// Bridges stdin and stdout until either side closes. stdout carries
    /// the protocol, so nothing else is ever written there.
    public func runOnStandardIO() async throws {
        try await run(input: standardInputLines()) { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    /// Sends each `input` line to the server and hands each message it
    /// sends to `output`. Returns when `input` has ended and every request
    /// sent has its answer (then the socket is closed); throws when the
    /// server can't be reached, refuses the connection, or closes it first,
    /// and when reading `input` or sending to the server fails.
    public func run<Input: AsyncSequence<String, any Error> & Sendable>(
        input: Input,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        var configuration = WebSocketClientConfiguration(
            // Pings keep NAT and proxy mappings open while a prompt is quiet.
            autoPing: .enabled(timePeriod: .seconds(30))
        )
        if let token {
            configuration.additionalHeaders[.authorization] = "Bearer \(token)"
        }
        // swift-log's default handler writes to stdout, which is the protocol.
        let silent = Logger(label: "nawa.connect") { _ in SwiftLogNoOpLogHandler() }
        let requests = UnansweredRequests()

        let closeFrame: WebSocketCloseFrame?
        do {
            closeFrame = try await WebSocketClient.connect(url: url, configuration: configuration, logger: silent) { inbound, outbound, _ in
                // Not awaited: stdin may never end once the server has closed,
                // and a stdin read can't always be cancelled.
                let sender = Task {
                    do {
                        for try await line in input {
                            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                            if case .request(let request)? = try? parseJSONRPCLine(line) {
                                requests.sent(request.id)
                            }
                            try await outbound.write(.text(line))
                        }
                    } catch {
                        // Closing ends the inbound loop below, which then
                        // reports this error instead of waiting on the server.
                        requests.senderFailed("\(error)")
                        try? await outbound.close(.goingAway, reason: nil)
                        return
                    }
                    // A client that writes its requests and then closes stdin
                    // (a script) still wants the answers: close only once
                    // they are all in.
                    if requests.inputEnded() {
                        try await outbound.close(.normalClosure, reason: nil)
                    }
                }
                defer { sender.cancel() }
                for try await message in inbound.messages(maxSize: 16 << 20) {
                    guard case .text(let text) = message else { continue }
                    output(text)
                    let answeredID: JSONRPCID?
                    switch try? parseJSONRPCLine(text) {
                    case .successResponse(let response)?: answeredID = response.id
                    case .errorResponse(let response)?: answeredID = response.id
                    default: answeredID = nil
                    }
                    if let answeredID, requests.answered(answeredID) {
                        try await outbound.close(.normalClosure, reason: nil)
                    }
                }
            }
        } catch let error as WebSocketClientError where error == .webSocketUpgradeFailed {
            throw ACPRemoteBridgeError.refused(url)
        } catch {
            throw ACPRemoteBridgeError.failed(url, "\(error)")
        }

        if let senderError = requests.senderError {
            throw ACPRemoteBridgeError.failed(url, senderError)
        }
        // Success only when the bridge itself closed: input over and every
        // answer in. A server that closes first, however politely, leaves
        // the client without its agent.
        if requests.isFinished { return }
        throw ACPRemoteBridgeError.closedByServer(url, closeFrame.map { "\($0.closeCode)" } ?? "without a close frame")
    }
}

/// The requests sent to the server that it hasn't answered yet, and
/// whether stdin has ended. One lock for both, so exactly one side sees
/// the moment the bridge may close: the end of input with nothing
/// pending, or the last answer after the end of input.
private final class UnansweredRequests: Sendable {
    private struct State {
        var pending: Set<JSONRPCID> = []
        var inputEnded = false
        var senderError: String?
    }
    private let state = Mutex(State())

    func sent(_ id: JSONRPCID) {
        state.withLock { _ = $0.pending.insert(id) }
    }

    /// Marks the end of input; true when nothing is waiting for an answer.
    func inputEnded() -> Bool {
        state.withLock { state in
            state.inputEnded = true
            return state.pending.isEmpty
        }
    }

    /// Marks `id` answered; true when that was the last answer input was
    /// waiting for.
    func answered(_ id: JSONRPCID) -> Bool {
        state.withLock { state in
            let wasPending = state.pending.remove(id) != nil
            return wasPending && state.inputEnded && state.pending.isEmpty
        }
    }

    func senderFailed(_ error: String) {
        state.withLock { $0.senderError = error }
    }

    var senderError: String? { state.withLock { $0.senderError } }

    /// Input has ended and every request has its answer.
    var isFinished: Bool { state.withLock { $0.inputEnded && $0.pending.isEmpty } }
}

public enum ACPRemoteBridgeError: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// The server answered the WebSocket upgrade with something else.
    case refused(String)
    case failed(String, String)
    case closedByServer(String, String)

    public var errorDescription: String? {
        switch self {
        case .refused(let url):
            return "\(url) refused the connection (a missing or wrong token, or not a nawa server)"
        case .failed(let url, let reason):
            return "could not talk to \(url): \(reason)"
        case .closedByServer(let url, let how):
            return "\(url) closed the connection (\(how))"
        }
    }

    public var description: String { errorDescription ?? "connect error" }
}
