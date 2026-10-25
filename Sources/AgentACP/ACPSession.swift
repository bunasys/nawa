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
    public func prompt(requestID: JSONRPCID, content: [ACPContentBlock]) {
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

    /// Use `modelID` for this session's next turns.
    public func setModel(_ modelID: String) {
        loop.model = modelID
    }

    /// Cancel the in-flight prompt turn, if any. The turn ends with the
    /// `cancelled` stop reason.
    public func cancel() {
        promptTask?.cancel()
    }

    private func runTurn(requestID: JSONRPCID, prompt: String, continuing: Bool) async {
        let messageID = "msg_\(UUID().uuidString.prefix(8))"
        var finalResult: AgentResult?
        var textStreamed = false
        do {
            let stream = loop.run(prompt: prompt, continuing: continuing)
            for try await event in stream {
                try Task.checkCancellation()
                if case .result(let result) = event { finalResult = result }
                await sendUpdate(for: event, messageID: messageID, textStreamed: &textStreamed)
            }
            // A failed turn is a JSON-RPC error, not a stop reason: clients
            // (Waku included) show an error's message to the user, whereas
            // the closest stop reason, `refusal`, reads as "the model declined".
            if let finalResult, finalResult.kind == .errorDuringExecution {
                let message = finalResult.errorMessage ?? "the agent turn failed"
                await sink.send(.makeError(id: requestID, code: .internalError, message: message), route: .session(sessionID))
                return
            }
            let stop = ACPStopReason(resultKind: finalResult?.kind ?? .success)
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
    /// `textStreamed` says whether the current model call's text already
    /// went out as stream deltas, so its `.assistant` doesn't repeat it.
    private func sendUpdate(for event: AgentEvent, messageID: String, textStreamed: inout Bool) async {
        switch event {
        case .initEvent:
            // No wire notification for the init event; it is internal.
            break
        case .assistant(let update):
            defer { textStreamed = false }
            if !update.text.isEmpty, !textStreamed {
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
            // Usage after every model call, not only at the end, so a client
            // sees an expensive turn while it is still running. `used` is
            // what this call read and wrote: how full the context is now.
            let usagePayload = ACPSessionUpdate.usageUpdate(
                used: update.usage.total,
                size: update.usage.total,
                costUSDCenticents: update.sessionCost
            )
            await emitUpdate(usagePayload)
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
                textStreamed = true
                let payload = ACPSessionUpdate.messageChunk(
                    kind: .agentMessageChunk,
                    messageID: messageID,
                    content: .text(delta)
                )
                await emitUpdate(payload)
            case .thinkingDelta(let delta):
                let payload = ACPSessionUpdate.messageChunk(
                    kind: .agentThoughtChunk,
                    messageID: messageID,
                    content: .text(delta)
                )
                await emitUpdate(payload)
            case .toolCallStart, .toolCallArgumentsDelta:
                // The tool call is announced with the finished turn.
                break
            }
        case .informational:
            break
        case .refusal(let notice):
            // ACP has no update for this, so the client sees it as text.
            // Text streamed before a refusal has already gone out; this
            // says it doesn't count.
            let payload = ACPSessionUpdate.messageChunk(
                kind: .agentMessageChunk,
                messageID: messageID,
                content: .text(Self.refusalText(notice))
            )
            await emitUpdate(payload)
        case .result:
            // Usage was already reported with each assistant update.
            break
        case .subAgent(let update):
            if let payload = Self.subAgentProgress(update) { await emitUpdate(payload) }
        }
    }

    /// `[claude-opus-5-5 declined this request (cyber). claude-opus-4-8 answers instead.]`
    static func refusalText(_ notice: RefusalNotice) -> String {
        var text = "\(notice.declinedBy ?? "The model") declined this request"
        if let category = notice.category { text += " (\(category))" }
        text += "."
        if let fallback = notice.answeredBy { text += " \(fallback) answers instead." }
        return "\n\n[\(text)]\n\n"
    }

    /// A sub-agent's progress as a `tool_call_update` of the parent's `task`
    /// call: running once it starts, then its latest step as the content
    /// (ACP replaces a tool call's content on each update). The final answer
    /// arrives with the tool result, like any other tool.
    static func subAgentProgress(_ update: SubAgentUpdate) -> JSON? {
        switch update.event {
        case .initEvent:
            let title = update.model.map { "Sub-agent (\($0))" } ?? "Sub-agent"
            return ACPSessionUpdate.toolCallUpdate(callID: update.callID, status: .running, title: title)
        case .assistant(let turn):
            var lines: [String] = []
            if !turn.text.isEmpty { lines.append(turn.text) }
            lines += turn.toolCalls.map { "→ \($0.name)" }
            guard !lines.isEmpty else { return nil }
            return ACPSessionUpdate.toolCallUpdate(callID: update.callID, status: .running, content: .text(lines.joined(separator: "\n")))
        default:
            return nil
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
