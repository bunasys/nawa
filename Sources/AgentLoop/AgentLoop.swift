import AgentCore
import AgentGateway
import Foundation

/// The working directory for tools in a session. Defaults to the process's
/// current directory at launch, cached once so it is stable across calls.
public struct WorkingDirectory: Sendable {
    public var url: URL

    public init(url: URL = WorkingDirectory.defaultURL) {
        self.url = url
    }

    public static let defaultURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// The agent loop: drives a session to completion, exercising tools.
///
/// This is the heart of the harness — the "agent loop as described with best
/// practices". Modeled on the agent-loop contract:
///
/// 1. **init event** — the run begins with session context.
/// 2. **Turn** — the model is asked to continue the conversation. It may
///    produce text, tool calls, or both.
/// 3. **Tool execution** — every requested tool runs; results come back as
///    tool messages (user role on the wire).
/// 4. **Repeat** — steps 2-3 repeat until the model produces a turn with no
///    tool calls, or a limit (max turns / budget) is hit.
/// 5. **result event** — the final answer + cumulative usage + turn count.
///
/// A reference type so that a long-lived session can be resumed: call
/// `run(prompt:continuing:true)` to append to the accumulated conversation.
/// Mutable state is guarded by a lock; concurrent `run` calls aren't supported.
public final class AgentLoop: @unchecked Sendable {
    /// The model the loop talks to.
    public let gateway: any LanguageModel
    /// The tools the loop can invoke.
    public let tools: ToolRegistry
    /// The system prompt injected at the start of every session.
    public let systemPrompt: String?
    /// Optional per-run limits.
    public let options: LoopOptions
    /// The working directory for the session's tools.
    public let cwd: String
    /// A hook invoked for every event (instrumentation/telemetry).
    public let onEvent: (@Sendable (AgentEvent) -> Void)?

    private let lock = NSLock()
    private var _session: Session
    private var _usage: Usage
    private var _turnCounter: Int

    /// The session this loop has been driving. Resumption: keep it, then run
    /// again with `run(prompt:continuing:true)`.
    public var session: Session {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    /// Running token/cost accounting for the current conversation.
    public var usage: Usage {
        lock.lock(); defer { lock.unlock() }
        return _usage
    }

    /// - Parameters:
    ///   - gateway: Language model to use.
    ///   - tools: Tool registry the model may call.
    ///   - systemPrompt: Optional instructions prepended to every conversation.
    ///   - options: Optional limits (maxTurns, maxBudgetUSD).
    ///   - cwd: Working directory for tools; defaults to the process cwd.
    ///   - onEvent: Observability hook; fires for every event the loop yields.
    public init(
        gateway: any LanguageModel,
        tools: ToolRegistry,
        systemPrompt: String? = nil,
        options: LoopOptions = LoopOptions(),
        cwd: String = WorkingDirectory().url.path,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) {
        self.gateway = gateway
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.options = options
        self.cwd = cwd
        self.onEvent = onEvent
        var session = Session(id: UUID().uuidString, cwd: cwd)
        if let systemPrompt, !systemPrompt.isEmpty {
            session.append(Message(role: .system, text: systemPrompt))
        }
        self._session = session
        self._usage = .zero
        self._turnCounter = 0
    }

    /// Run a prompt, streaming `AgentEvent`s.
    public func run(prompt: String, continuing: Bool = false) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    // Emit the init event once per *conversation*, not per run.
                    if !continuing {
                        self.emit(.initEvent(self.session))
                    }

                    // Append the user's message to the live session.
                    self.appendUser(prompt)

                    while true {
                        if let maxTurns = self.options.maxTurns, self._turnCounter >= maxTurns {
                            self.emit(.informational("Hit maxTurns (\(maxTurns)) — stopping."))
                            let result = AgentResult(
                                kind: .errorMaxTurns,
                                usage: self._usage,
                                numTurns: self._turnCounter,
                                sessionID: self._session.id
                            )
                            self.emit(.result(result))
                            continuation.yield(.result(result))
                            continuation.finish()
                            return
                        }

                        // 1. Ask the model.
                        let request = ModelRequest(
                            model: nil,
                            messages: self._session.messages,
                            tools: self.options.sendTools ? self.tools.definitions : nil,
                            maxOutputTokens: self.options.maxOutputTokens,
                            temperature: self.options.temperature
                        )

                        let response = try await self.gateway.complete(request)
                        self._usage.accumulate(response.usage)

                        // Enforce the spend cap, if any.
                        if let maxBudget = self.options.maxBudgetUSD,
                           let cost = self.totalCost, cost >= maxBudget
                        {
                            let result = AgentResult(
                                kind: .errorMaxBudgetUSD,
                                usage: self._usage,
                                numTurns: self._turnCounter,
                                sessionID: self._session.id
                            )
                            self.emit(.result(result))
                            continuation.yield(.result(result))
                            continuation.finish()
                            return
                        }

                        // 2. Persist the assistant turn and emit it.
                        let update = AssistantUpdate(
                            text: response.message.text,
                            toolCalls: response.message.toolCalls,
                            usage: response.usage,
                            stopReason: response.finishReason
                        )
                        self._session.append(response.message)
                        self.emit(.assistant(update))
                        continuation.yield(.assistant(update))

                        // 3. No tool calls → the run is done.
                        guard !response.message.toolCalls.isEmpty else {
                            let result = AgentResult(
                                kind: .success,
                                text: response.message.text,
                                usage: self._usage,
                                numTurns: self._turnCounter,
                                sessionID: self._session.id,
                                stopReason: response.finishReason,
                                costEstimate: self.totalCost
                            )
                            self.emit(.result(result))
                            continuation.yield(.result(result))
                            continuation.finish()
                            return
                        }

                        // 4. Execute the requested tools.
                        self._turnCounter += 1
                        let results = await self.runTools(response.message.toolCalls)
                        for result in results {
                            self.emit(.toolResult(result))
                        }
                        self._session.messages.append(contentsOf: results.map { $0.asMessage })
                        continuation.yield(.toolResults(results))
                    }
                } catch {
                    let result = AgentResult(
                        kind: .errorDuringExecution,
                        usage: self._usage,
                        numTurns: self._turnCounter,
                        sessionID: self._session.id
                    )
                    self.emit(.informational("Loop error: \(error)"))
                    self.emit(.result(result))
                    continuation.yield(.result(result))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func appendUser(_ prompt: String) {
        lock.lock(); defer { lock.unlock() }
        _session.append(Message(role: .user, text: prompt))
    }

    /// Run each requested tool, collecting results. Tools run sequentially for
    /// predictability; results are gathered in call order.
    private func runTools(_ toolCalls: [ToolCall]) async -> [ToolCallResult] {
        var results: [ToolCallResult] = []
        for call in toolCalls {
            if let tool = self.tools.tool(named: call.name) {
                results.append(await tool.result(for: call))
            } else {
                results.append(
                    ToolCallResult(callID: call.id, name: call.name, content: "no tool named \(call.name)", isError: true)
                )
            }
        }
        return results
    }

    /// Approximate US-dollar cost of the conversation so far, from per-token
    /// pricing if configured (nil otherwise).
    public var totalCost: Double? {
        guard let pricing = self.options.pricing else { return nil }
        return (Double(usage.inputTokens) * pricing.inputPer1K / 1000)
            + (Double(usage.outputTokens) * pricing.outputPer1K / 1000)
    }

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }
}

/// Per-token USD pricing used for cost estimation (`AgentResult.costEstimate`).
public struct Pricing: Sendable, Codable, Equatable {
    /// Cost per 1,000 input tokens, in USD.
    public var inputPer1K: Double
    /// Cost per 1,000 output tokens, in USD.
    public var outputPer1K: Double

    public init(inputPer1K: Double = 0, outputPer1K: Double = 0) {
        self.inputPer1K = inputPer1K
        self.outputPer1K = outputPer1K
    }
}

/// Tunable limits for the loop.
public struct LoopOptions: Sendable {
    // No mutable defaults in a Sendable struct — everything is set via init.
    /// Maximum number of tool-use turns. Nil = unlimited.
    public var maxTurns: Int?
    /// Maximum spend in USD. Nil = unlimited.
    public var maxBudgetUSD: Double?
    /// Maximum output tokens per model call.
    public var maxOutputTokens: Int?
    /// Sampling temperature.
    public var temperature: Double?
    /// Whether to include tool definitions in model requests.
    public var sendTools: Bool
    /// Per-model pricing, if cost is to be surfaced.
    public var pricing: Pricing?

    public init(
        maxTurns: Int? = nil,
        maxBudgetUSD: Double? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        sendTools: Bool = true,
        pricing: Pricing? = nil
    ) {
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.sendTools = sendTools
        self.pricing = pricing
    }
}
