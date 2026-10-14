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
    private var _model: String?
    /// Size of the conversation at the last model call (prompt + reply), the
    /// signal for compaction.
    private var _contextTokens = 0
    /// Facts saved with the `remember` tool. They are restated verbatim after
    /// every compaction so a summary cannot lose them.
    private var _notes: [String] = []

    /// The model id sent with each request; `nil` lets the gateway pick its
    /// configured or discovered default. Clients may switch it between turns
    /// (ACP `session/set_model`).
    public var model: String? {
        get { lock.lock(); defer { lock.unlock() }; return _model }
        set { lock.lock(); defer { lock.unlock() }; _model = newValue }
    }

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
                            self.finish(continuation, self.result(.errorMaxTurns))
                            return
                        }

                        // 1. Ask the model, after trimming what it no longer needs.
                        try await self.shrinkContext()
                        let request = ModelRequest(
                            model: self.model,
                            messages: self._session.messages,
                            tools: self.options.sendTools ? self.toolDefinitions : nil,
                            maxOutputTokens: self.options.maxOutputTokens,
                            temperature: self.options.temperature
                        )

                        let response = try await self.gateway.complete(request)
                        self._usage.accumulate(response.usage)
                        self._contextTokens = response.usage.total

                        // Enforce the spend cap, if any.
                        if let maxBudget = self.options.maxBudgetUSD,
                           let cost = self.totalCost, cost >= maxBudget
                        {
                            self.finish(continuation, self.result(.errorMaxBudgetUSD))
                            return
                        }

                        // 2. Persist the assistant turn and emit it.
                        let update = AssistantUpdate(
                            text: response.message.text,
                            toolCalls: response.message.toolCalls,
                            usage: response.usage,
                            stopReason: response.finishReason,
                            sessionUsage: self._usage,
                            sessionCost: self.totalCost
                        )
                        self._session.append(response.message)
                        self.emit(.assistant(update))
                        continuation.yield(.assistant(update))

                        // 3. No tool calls → the run is done.
                        guard !response.message.toolCalls.isEmpty else {
                            let success = self.result(.success, text: response.message.text, stopReason: response.finishReason)
                            self.finish(continuation, success)
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
                    self.emit(.informational("Loop error: \(error)"))
                    let failure = self.result(.errorDuringExecution, errorMessage: error.localizedDescription)
                    self.finish(continuation, failure)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func appendUser(_ prompt: String) {
        lock.lock(); defer { lock.unlock() }
        _session.append(Message(role: .user, text: prompt))
    }

    private func result(
        _ kind: AgentResultKind,
        text: String? = nil,
        stopReason: StopReason? = nil,
        errorMessage: String? = nil
    ) -> AgentResult {
        AgentResult(
            kind: kind,
            text: text,
            usage: _usage,
            numTurns: _turnCounter,
            sessionID: _session.id,
            stopReason: stopReason,
            costEstimate: totalCost,
            errorMessage: errorMessage
        )
    }

    private func finish(_ continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation, _ result: AgentResult) {
        emit(.result(result))
        continuation.yield(.result(result))
        continuation.finish()
    }

    // MARK: Tools

    /// The registry's tools plus the ones the loop itself provides. The order
    /// never changes between turns, so the request prefix stays cacheable.
    private var toolDefinitions: [ToolDefinition] {
        var definitions = tools.definitions
        if options.subAgents { definitions.append(Self.taskDefinition) }
        if options.compaction != nil { definitions.append(Self.rememberDefinition) }
        return definitions
    }

    /// Run each requested tool, collecting results. Tools run sequentially for
    /// predictability; results are gathered in call order.
    private func runTools(_ toolCalls: [ToolCall]) async -> [ToolCallResult] {
        var results: [ToolCallResult] = []
        for call in toolCalls {
            results.append(await runTool(call))
        }
        return results
    }

    private func runTool(_ call: ToolCall) async -> ToolCallResult {
        let isTask = options.subAgents && call.name == Self.taskDefinition.name
        let isRemember = options.compaction != nil && call.name == Self.rememberDefinition.name
        if isTask {
            return await runSubAgent(call)
        }
        if isRemember {
            let note = call.arguments.objectValue?["note"]?.stringValue ?? ""
            if note.isEmpty {
                return ToolCallResult(callID: call.id, name: call.name, content: "missing string argument 'note'", isError: true)
            }
            _notes.append(note)
            return ToolCallResult(callID: call.id, name: call.name, content: "Noted.")
        }
        guard let tool = tools.tool(named: call.name) else {
            return ToolCallResult(callID: call.id, name: call.name, content: "no tool named \(call.name)", isError: true)
        }
        return await tool.result(for: call)
    }

    static let taskDefinition = ToolDefinition(
        name: "task",
        description: """
        Hand a self-contained job to a sub-agent that starts with a fresh, empty conversation \
        and the same tools (except task). Only its final answer comes back, so use it for \
        exploration whose intermediate output you do not need, e.g. "find where session \
        cancellation is handled and list the files and functions involved". Say exactly \
        what the answer should contain.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The complete job description; the sub-agent sees nothing else."),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ])
    )

    static let rememberDefinition = ToolDefinition(
        name: "remember",
        description: """
        Save a key fact (a decision, a file location, a constraint) so it survives when old \
        parts of this conversation are summarized to save space. Keep notes short.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "note": .object(["type": .string("string"), "description": .string("The fact to keep.")]),
            ]),
            "required": .array([.string("note")]),
        ])
    )

    /// Run a `task` call in a fresh loop. Its tool output never enters this
    /// conversation; only the final answer does. Its spend counts here, so
    /// the budget cap and totals include it.
    private func runSubAgent(_ call: ToolCall) async -> ToolCallResult {
        let prompt = call.arguments.objectValue?["prompt"]?.stringValue ?? ""
        if prompt.isEmpty {
            return ToolCallResult(callID: call.id, name: call.name, content: "missing string argument 'prompt'", isError: true)
        }
        var childOptions = options
        childOptions.subAgents = false
        let child = AgentLoop(gateway: gateway, tools: tools, systemPrompt: systemPrompt, options: childOptions, cwd: cwd)
        child.model = options.helperModel ?? model
        emit(.informational("Sub-agent started: \(prompt.prefix(80))"))

        var childResult: AgentResult?
        do {
            for try await event in child.run(prompt: prompt) {
                if case .result(let result) = event { childResult = result }
            }
        } catch {
            return ToolCallResult(callID: call.id, name: call.name, content: "sub-agent failed: \(error)", isError: true)
        }
        guard let childResult else {
            return ToolCallResult(callID: call.id, name: call.name, content: "sub-agent ended without a result", isError: true)
        }
        _usage.accumulate(childResult.usage)
        guard childResult.isSuccess else {
            let reason = childResult.errorMessage ?? childResult.kind.rawValue
            return ToolCallResult(callID: call.id, name: call.name, content: "sub-agent stopped: \(reason)", isError: true)
        }
        return ToolCallResult(callID: call.id, name: call.name, content: childResult.text ?? "")
    }

    // MARK: Context size

    private func shrinkContext() async throws {
        if let keep = options.keepToolResults {
            _session.messages = ContextShrinking.clearingOldToolResults(_session.messages, keep: keep)
        }
        guard let compaction = options.compaction, _contextTokens >= compaction.atContextTokens else { return }
        try await compact(keepRecent: compaction.keepRecentMessages)
    }

    /// Replace the older part of the conversation with a model-written
    /// summary, keeping the recent messages word for word.
    private func compact(keepRecent: Int) async throws {
        let messages = _session.messages
        guard let cut = ContextShrinking.compactionCut(messages, keepRecent: keepRecent) else { return }
        let systemMessages = messages.prefix { $0.role == .system }
        let older = messages[systemMessages.count..<cut]

        let request = ModelRequest(
            model: options.helperModel ?? model,
            messages: [
                Message(role: .system, text: ContextShrinking.summarizerInstructions),
                Message(role: .user, text: ContextShrinking.transcript(Array(older))),
            ],
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature
        )
        let response = try await gateway.complete(request)
        _usage.accumulate(response.usage)

        var summary = "Summary of the conversation so far (older messages were compacted):\n\n\(response.message.text)"
        if !_notes.isEmpty {
            summary += "\n\nNotes you saved with remember:\n" + _notes.map { "- \($0)" }.joined(separator: "\n")
        }
        _session.messages = Array(systemMessages) + [Message(role: .user, text: summary)] + messages[cut...]
        // The next model call reports the new size; until then, don't compact again.
        _contextTokens = 0
        emit(.informational("Compacted \(older.count) older messages into a summary."))
    }

    // MARK: Cost

    /// Approximate US-dollar cost of the conversation so far, from per-token
    /// pricing if configured (nil otherwise).
    public var totalCost: Double? {
        guard let pricing = self.options.pricing else { return nil }
        return pricing.cost(of: usage)
    }

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }
}

/// Per-token USD pricing used for cost estimation (`AgentResult.costEstimate`).
public struct Pricing: Sendable, Codable, Equatable {
    /// Cost per 1,000 fresh input tokens, in USD.
    public var inputPer1K: Double
    /// Cost per 1,000 output tokens, in USD.
    public var outputPer1K: Double
    /// Cost per 1,000 input tokens read from the prompt cache, in USD.
    public var cacheReadPer1K: Double
    /// Cost per 1,000 input tokens written to the prompt cache, in USD.
    public var cacheWritePer1K: Double

    /// Cache prices default to Anthropic's ratios (reads 0.1×, five-minute
    /// writes 1.25× the input price); pass them for other providers.
    public init(inputPer1K: Double = 0, outputPer1K: Double = 0, cacheReadPer1K: Double? = nil, cacheWritePer1K: Double? = nil) {
        self.inputPer1K = inputPer1K
        self.outputPer1K = outputPer1K
        self.cacheReadPer1K = cacheReadPer1K ?? inputPer1K * 0.1
        self.cacheWritePer1K = cacheWritePer1K ?? inputPer1K * 1.25
    }

    public func cost(of usage: Usage) -> Double {
        let input = Double(usage.inputTokens) * inputPer1K
        let output = Double(usage.outputTokens) * outputPer1K
        let cacheRead = Double(usage.cacheReadTokens) * cacheReadPer1K
        let cacheWrite = Double(usage.cacheWriteTokens) * cacheWritePer1K
        return (input + output + cacheRead + cacheWrite) / 1000
    }
}

/// When to summarize the older part of a conversation.
public struct Compaction: Sendable {
    /// Compact once a model call's prompt plus reply reaches this many tokens.
    public var atContextTokens: Int
    /// How many of the newest messages are kept word for word.
    public var keepRecentMessages: Int

    public init(atContextTokens: Int, keepRecentMessages: Int = 20) {
        self.atContextTokens = atContextTokens
        self.keepRecentMessages = keepRecentMessages
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
    /// Keep only this many recent tool results in full; older ones are
    /// replaced with a marker. Nil = keep everything.
    public var keepToolResults: Int?
    /// Summarize long conversations. Also offers the model a `remember` tool
    /// whose notes survive the summary. Nil = never summarize.
    public var compaction: Compaction?
    /// Offer the model a `task` tool that runs a sub-agent in a fresh conversation.
    public var subAgents: Bool
    /// A cheaper model for sub-agents and summaries. Nil = the session's model.
    public var helperModel: String?

    public init(
        maxTurns: Int? = nil,
        maxBudgetUSD: Double? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        sendTools: Bool = true,
        pricing: Pricing? = nil,
        keepToolResults: Int? = nil,
        compaction: Compaction? = nil,
        subAgents: Bool = false,
        helperModel: String? = nil
    ) {
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.sendTools = sendTools
        self.pricing = pricing
        self.keepToolResults = keepToolResults
        self.compaction = compaction
        self.subAgents = subAgents
        self.helperModel = helperModel
    }
}
