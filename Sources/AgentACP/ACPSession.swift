import AgentCore
import AgentGateway
import AgentJSONRPC
import AgentLoop
import AgentMCP
import AgentTools
import Foundation

/// A single ACP session: one conversation between a client and the agent.
///
/// The session owns an `AgentLoop` (the agent's brain + tools) and translates
/// the loop's `AgentEvent` stream into ACP `session/update` notifications and a
/// terminal `session/prompt` response. One session runs at most one prompt
/// turn at a time; `cancel()` aborts the in-flight turn.
public actor ACPSession {
    public let sessionID: String
    public let cwd: String

    private let loop: AgentLoop
    private let sink: ACPMessageSink
    private var promptTask: Task<Void, Never>?

    /// Builds a session for a prompt turn.
    /// - Parameters:
    ///   - sessionID: The ACP session id (chosen by the server).
    ///   - cwd: Working directory for tools in this session.
    ///   - loop: A configured agent loop bound to a gateway and tool registry.
    ///   - sink: Where to send outbound JSON-RPC messages (notifications + the
    ///     prompt response). Routed to the session-scoped stream.
    public init(sessionID: String, cwd: String, loop: AgentLoop, sink: ACPMessageSink) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.loop = loop
        self.sink = sink
    }

    /// Begin processing a user prompt. Streams `session/update` notifications
    /// to the sink, then delivers the `session/prompt` response (correlated by
    /// `requestID`) when the loop finishes.
    ///
    /// If a prompt is already running it is cancelled first.
    public func prompt(requestID: Int, content: [ACPContentBlock]) {
        promptTask?.cancel()
        let text = content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
        let firstPrompt = loop.session.messages.allSatisfy { $0.role != .user }
        promptTask = Task { [weak self] in
            await self?.runTurn(requestID: requestID, prompt: text, continuing: !firstPrompt)
        }
    }

    /// Cancel the in-flight prompt turn, if any. The turn ends with the
    /// `cancelled` stop reason.
    public func cancel() {
        promptTask?.cancel()
    }

    private func runTurn(requestID: Int, prompt: String, continuing: Bool) async {
        let messageID = "msg_\(UUID().uuidString.prefix(8))"
        var finalKind: AgentResultKind = .success
        do {
            let stream = loop.run(prompt: prompt, continuing: continuing)
            for try await event in stream {
                try Task.checkCancellation()
                if case .result(let result) = event { finalKind = result.kind }
                await sendUpdate(for: event, messageID: messageID)
            }
            let stop = ACPStopReason(resultKind: finalKind)
            await sink.send(.makeSuccess(id: requestID, result: .object(["stopReason": .string(stop.rawValue)])), route: .session(sessionID))
        } catch is CancellationError {
            // The turn was cancelled by the client via `session/cancel`.
            await sink.send(
                .makeSuccess(id: requestID, result: .object(["stopReason": .string(ACPStopReason.cancelled.rawValue)])),
                route: .session(sessionID)
            )
        } catch {
            await sink.send(
                .makeError(id: requestID, code: .internalError, message: "agent turn failed: \(error)"),
                route: .session(sessionID)
            )
        }
    }

    /// Translate one `AgentEvent` into the appropriate ACP `session/update`
    /// notification(s) and emit them on the session-scoped sink.
    private func sendUpdate(for event: AgentEvent, messageID: String) async {
        switch event {
        case .initEvent:
            // No wire notification for the init event; it is internal.
            break
        case .assistant(let update):
            if !update.text.isEmpty {
                let payload = ACPSessionUpdate.messageChunk(
                    kind: .agentMessageChunk,
                    messageID: messageID,
                    content: .text(update.text)
                )
                await emitUpdate(payload)
            }
            for call in update.toolCalls {
                let payload = ACPSessionUpdate.toolCall(
                    callID: call.id,
                    title: call.name,
                    kind: .other,
                    status: .pending
                )
                await emitUpdate(payload)
            }
        case .toolResult(let result):
            let status: ACPToolCallStatus = result.isError ? .failed : .completed
            let payload = ACPSessionUpdate.toolCallUpdate(
                callID: result.callID,
                status: status,
                content: .text(result.content)
            )
            await emitUpdate(payload)
        case .toolResults(let results):
            for result in results {
                let status: ACPToolCallStatus = result.isError ? .failed : .completed
                let payload = ACPSessionUpdate.toolCallUpdate(
                    callID: result.callID,
                    status: status,
                    content: .text(result.content)
                )
                await emitUpdate(payload)
            }
        case .stream(let update):
            switch update {
            case .textDelta(let delta):
                let payload = ACPSessionUpdate.messageChunk(
                    kind: .agentMessageChunk,
                    messageID: messageID,
                    content: .text(delta)
                )
                await emitUpdate(payload)
            default:
                break
            }
        case .informational:
            break
        case .result(let result):
            // Surface a usage_update at the end of the turn.
            let usagePayload = ACPSessionUpdate.usageUpdate(
                used: result.usage.total,
                size: result.usage.total,
                costUSDCenticents: result.costEstimate
            )
            await emitUpdate(usagePayload)
        }
    }

    private func emitUpdate(_ update: JSON) async {
        let notification = JSONRPCMessage.makeNotification(
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": update,
            ])
        )
        await sink.send(notification, route: .session(sessionID))
    }
}
