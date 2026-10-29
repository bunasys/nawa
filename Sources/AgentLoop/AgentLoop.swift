import AgentCore
import AgentGateway
import AgentInstructions
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
///    tool calls, a limit (max turns / budget) is hit, or the run is caught
///    repeating itself (`LoopDetector`).
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
    /// The caller's instructions: they follow Nawa's first principles in the
    /// session's system message (`SystemPrompt.composed`), never replace them.
    public let systemPrompt: String?
    /// Limits and token savers. Can be changed while a run goes on (the
    /// repl's `/config set`): each turn reads the current value. Which tools
    /// are offered (`subAgents`, `compaction` on or off) should stay as the
    /// session started, or the request prefix stops being cacheable.
    public var options: LoopOptions {
        get { optionsLock.withLock { _options } }
        set { optionsLock.withLock { _options = newValue } }
    }
    private var _options: LoopOptions
    /// Its own lock, apart from `lock`: code holding `lock` reads options.
    private let optionsLock = NSLock()
    /// The working directory for the session's tools.
    public let cwd: String
    /// A hook invoked for every event (instrumentation/telemetry).
    public let onEvent: (@Sendable (AgentEvent) -> Void)?
    /// Where the session is recorded (proposal 0005); nil records nothing.
    public let journal: (any SessionJournal)?
    /// For a sub-agent: the session and `task` call it works for, written
    /// into its `session_started` record.
    var journalParent: JournalParent?

    private let lock = NSLock()
    private var _session: Session
    private var _usage: Usage
    private var _turnCounter: Int
    private var _loopDetector: LoopDetector
    private var _model: String?
    /// Size of the conversation at the last model call (prompt + reply), the
    /// signal for compaction.
    private var _contextTokens = 0
    /// Facts saved with the `remember` tool. They are restated verbatim after
    /// every compaction so a summary cannot lose them.
    private var _notes: [String] = []
    /// The part of `_usage` spent on `options.helperModel` (sub-agents and
    /// summaries), priced with `options.helperPricing`.
    private var _helperUsage: Usage = .zero
    /// Where the current run's prompt sits in `_session.messages`.
    private var _runPromptIndex = 0
    /// The last refusal of the current run, reported with its result.
    private var _lastRefusal: RefusalNotice?
    /// The provider that wrote the last reply, when the gateway said so.
    private var _answeringProvider: String?
    /// The prompt a model declined in the last run, kept until the next run
    /// or a compaction so `removeDeclinedRequest` can take it out.
    private var _declined: DeclinedRequest?
    /// Messages from `steer`, waiting for the next model call.
    private var _steering: [String] = []
    /// Whether this run already took its one model call past `maxTurns` to
    /// answer a steer. One only, so steering can't lift the cap.
    private var _tookTurnCapGrace = false
    /// Whether `session_started` is written; nothing is recorded before it.
    private var _journalStarted = false
    /// Set by `init(restoring:)`: the session's messages are already in
    /// the journal, so starting it again must not record them twice.
    private var _isRestored = false
    /// The tool set last recorded, so an unchanged set isn't written again.
    private var _recordedTools: (definitions: [ToolDefinition], id: String)?

    private struct DeclinedRequest {
        var promptIndex: Int
        /// The model the run started on, restored when the prompt is removed.
        var modelBefore: String?
    }

    /// The model id sent with each request; `nil` lets the gateway pick its
    /// configured or discovered default. Clients may switch it between turns
    /// (ACP `session/set_model`).
    public var model: String? {
        get { lock.lock(); defer { lock.unlock() }; return _model }
        set {
            lock.lock()
            let previous = _model
            _model = newValue
            let isRecording = _journalStarted
            lock.unlock()
            if isRecording && previous != newValue {
                record(.modelChanged(from: previous, to: newValue))
            }
        }
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
    ///   - systemPrompt: Instructions added after Nawa's first principles
    ///     (`SystemPrompt.firstPrinciples`), which every session starts with.
    ///   - options: Optional limits (maxTurns, loop check, maxBudgetUSD).
    ///   - cwd: Working directory for tools; defaults to the process cwd.
    ///   - sessionID: The session's id, also its id in the journal. ACP
    ///     passes its own session id so the two match.
    ///   - journal: Where to record the session; nil records nothing.
    ///   - onEvent: Observability hook; fires for every event the loop yields.
    public init(
        gateway: any LanguageModel,
        tools: ToolRegistry,
        systemPrompt: String? = nil,
        options: LoopOptions = LoopOptions(),
        cwd: String = WorkingDirectory().url.path,
        sessionID: String = UUID().uuidString,
        journal: (any SessionJournal)? = nil,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) {
        self.gateway = gateway
        self.tools = tools
        self.systemPrompt = systemPrompt
        self._options = options
        self.cwd = cwd
        self.journal = journal
        self.onEvent = onEvent
        var session = Session(id: sessionID, cwd: cwd)
        session.append(Message(role: .system, text: SystemPrompt.composed(systemPrompt)))
        self._session = session
        self._usage = .zero
        self._turnCounter = 0
        self._loopDetector = LoopDetector(checkAfterTurns: options.loopCheckAfterTurns)
    }

    /// A loop that goes on with a session rebuilt from its journal
    /// (`JournalReader.replay`): same id, context, model, notes and totals.
    ///
    /// Pass the journal the state was read from: the restored loop appends
    /// to it and doesn't record the old messages again. `systemPrompt` is
    /// for sub-agents only; the session keeps the system prompt it had.
    /// Continue it with `run(prompt:continuing: true)`.
    public convenience init(
        restoring state: SessionState,
        gateway: any LanguageModel,
        tools: ToolRegistry,
        systemPrompt: String? = nil,
        options: LoopOptions = LoopOptions(),
        journal: (any SessionJournal)? = nil,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) {
        self.init(
            gateway: gateway,
            tools: tools,
            systemPrompt: systemPrompt,
            options: options,
            cwd: state.cwd,
            sessionID: state.sessionID,
            journal: journal,
            onEvent: onEvent
        )
        _session.messages = state.messages
        _model = state.model
        _notes = state.notes
        _usage = state.usage
        // Helper usage only counts apart when there is a helper to price it.
        _helperUsage = options.helperModel == nil ? .zero : state.helperUsage
        _contextTokens = state.contextTokens
        _isRestored = true
    }

    /// Tell the agent something while it works, e.g. "wrap up and answer now".
    ///
    /// The message joins the conversation as a user message just before the
    /// next model call, after the current turn's tool results, and the run
    /// goes on with everything it has done so far. A reply that would have
    /// ended the run is followed by the message instead.
    ///
    /// A run at its `maxTurns` gets one more model call to answer it, once per
    /// run. A text answer to that call is the run's answer (`success`); if it
    /// calls tools instead, they still run (so a "submit" tool gets its
    /// answer) and the run ends as `errorMaxTurns`. A run that ends
    /// another way (budget, refusal, loop detector, error) drops the message,
    /// since it was about that run, and says so with a "Not delivered: …"
    /// informational event. Sent between runs, it waits for the next one.
    ///
    /// A model call made only to answer a steer counts as a turn toward
    /// `maxTurns`. The "Steered: …" and "Not delivered: …" notes reach the
    /// event stream and `onEvent` only; ACP sessions don't show informational
    /// events.
    public func steer(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        _steering.append(message)
    }

    private var hasSteering: Bool {
        lock.lock(); defer { lock.unlock() }
        return !_steering.isEmpty
    }

    /// Empties the steer queue: its messages as one text, or nil when empty.
    private func takeSteering() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !_steering.isEmpty else { return nil }
        let text = _steering.joined(separator: "\n\n")
        _steering = []
        return text
    }

    /// Run a prompt, streaming `AgentEvent`s.
    public func run(prompt: String, continuing: Bool = false) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    self.startJournalIfNeeded()
                    // Emit the init event once per *conversation*, not per run.
                    if !continuing {
                        let initEvent = AgentEvent.initEvent(self.session)
                        self.emit(initEvent)
                        continuation.yield(initEvent)
                    }

                    // Append the user's message to the live session.
                    self.appendUser(prompt)
                    self.record(.runStarted(promptMessageID: self._session.messages[self._runPromptIndex].id, model: self.model))

                    while true {
                        if let maxTurns = self.options.maxTurns, self._turnCounter >= maxTurns {
                            // A steer ("wrap up now") is most likely to come just
                            // as the turns run out, so it gets one call to answer.
                            let mayAnswerSteer = self.hasSteering && !self._tookTurnCapGrace
                            if !mayAnswerSteer {
                                self.emit(.informational("Hit maxTurns (\(maxTurns)) — stopping."))
                                self.finish(continuation, self.result(.errorMaxTurns))
                                return
                            }
                            self._tookTurnCapGrace = true
                        }

                        // 1. Ask the model, after trimming what it no longer needs
                        // and adding what the caller steered in meanwhile.
                        try await self.shrinkContext { note in
                            self.emit(note)
                            continuation.yield(note)
                        }
                        if let steered = self.takeSteering() {
                            let message = Message(role: .user, text: steered)
                            self._session.append(message)
                            self.recordAppended([message])
                            self.record(.steered(messageID: message.id))
                            let note = AgentEvent.informational("Steered: \(steered)")
                            self.emit(note)
                            continuation.yield(note)
                        }
                        let request = ModelRequest(
                            model: self.model,
                            messages: self._session.messages,
                            tools: self.options.sendTools ? self.toolDefinitions : nil,
                            maxOutputTokens: self.options.maxOutputTokens,
                            temperature: self.options.temperature,
                            mayFailOver: self.mayFailOver,
                            sessionID: self._session.id
                        )

                        let (response, _) = try await self.callModel(request, purpose: .turn, stream: self.options.streamReplies) { update in
                            self.emit(.stream(update))
                            continuation.yield(.stream(update))
                        }
                        self._usage.accumulate(response.usage)
                        self._contextTokens = response.usage.total
                        try self.checkAnsweringProvider(response) { note in
                            self.emit(note)
                            continuation.yield(note)
                        }

                        // Enforce the spend cap, if any.
                        if let maxBudget = self.options.maxBudgetUSD,
                           let cost = self.totalCost, cost >= maxBudget
                        {
                            self.record(.message(response.message, appendedToContext: false))
                            self.finish(continuation, self.result(.errorMaxBudgetUSD))
                            return
                        }

                        // A declined reply is dropped, partial text included:
                        // it is not an answer. Ask the fallback model, if any.
                        if response.finishReason == .refusal {
                            self.record(.message(response.message, appendedToContext: false))
                            let notice = self.recordRefusal(response)
                            self.record(.refusal(notice))
                            self.emit(.refusal(notice))
                            continuation.yield(.refusal(notice))
                            if notice.answeredBy != nil { continue }
                            self.finish(continuation, self.result(.refused))
                            return
                        }
                        // Anthropic's server-side fallback already answered
                        // in the model's place; say so, and keep the answer.
                        if let declinedModel = response.declinedBy.first {
                            let notice = RefusalNotice(declinedBy: declinedModel, answeredBy: response.model)
                            self.rememberDeclinedPrompt(notice)
                            self.record(.refusal(notice))
                            self.emit(.refusal(notice))
                            continuation.yield(.refusal(notice))
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
                        self.recordAppended([response.message])
                        self.emit(.assistant(update))
                        continuation.yield(.assistant(update))

                        // 3. No tool calls → the run is done, unless the caller
                        // steered in a message the model hasn't seen yet.
                        if response.message.toolCalls.isEmpty && self.hasSteering {
                            // Counted as a turn, so steering after every answer
                            // still reaches maxTurns.
                            self._turnCounter += 1
                            continue
                        }
                        guard !response.message.toolCalls.isEmpty else {
                            let success = self.result(.success, text: response.message.text, stopReason: response.finishReason)
                            self.finish(continuation, success)
                            return
                        }

                        // 4. Execute the requested tools.
                        self._turnCounter += 1
                        let results = await self.runTools(response.message.toolCalls) { event in
                            self.emit(event)
                            continuation.yield(event)
                        }
                        // A cancelled run stops here rather than asking the model again.
                        try Task.checkCancellation()
                        for result in results {
                            self.emit(.toolResult(result))
                        }
                        // The context gets a pointer for output it already has;
                        // events and the loop check above see the real results.
                        let contextResults = ContextShrinking.dedupingRepeatedResults(results, against: self._session.messages)
                        let resultMessages = contextResults.map { $0.asMessage }
                        self._session.messages.append(contentsOf: resultMessages)
                        self.recordAppended(resultMessages)
                        continuation.yield(.toolResults(results))

                        if let repeatedTools = self._loopDetector.record(calls: response.message.toolCalls, results: results) {
                            let message = "Stopped after \(self._turnCounter) tool turns: the same \(repeatedTools.joined(separator: ", ")) calls returned the same results \(LoopDetector.repeatLimit) times in the last \(LoopDetector.window) turns."
                            self.emit(.informational(message))
                            self.finish(continuation, self.result(.errorDuringExecution, errorMessage: message))
                            return
                        }
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

    /// Starts a run: appends the prompt and resets the turn counter and the
    /// loop check, so both apply to each prompt rather than the whole conversation.
    private func appendUser(_ prompt: String) {
        lock.lock(); defer { lock.unlock() }
        let countBefore = _session.messages.count
        // A run interrupted between the model's tool calls and their results
        // left calls unanswered, and providers refuse such a conversation.
        if let last = _session.messages.last, last.role == .assistant {
            for call in last.toolCalls {
                let result = ToolCallResult(callID: call.id, name: call.name, content: "interrupted by the user before it finished", isError: true)
                _session.append(result.asMessage)
            }
        }
        _session.append(Message(role: .user, text: prompt))
        recordAppended(_session.messages[countBefore...])
        _runPromptIndex = _session.messages.count - 1
        _turnCounter = 0
        _loopDetector.reset()
        _lastRefusal = nil
        _declined = nil
        _tookTurnCapGrace = false
    }

    // MARK: Refusals

    /// Notes a declined reply and picks the model to ask next: the
    /// configured `fallbackModel`, else the one the provider recommends.
    /// There is one retry per run: a refusal from the fallback is final.
    private func recordRefusal(_ response: ModelResponse) -> RefusalNotice {
        let declinedModel = response.model ?? model
        let category = response.refusal?.category
        // These come from a prompt asking the model to write out its
        // reasoning; Anthropic recommends rewording, not another model.
        let anotherModelWontHelp = category == "reasoning_extraction"
        let candidate = options.fallbackModel ?? response.refusal?.recommendedModel
        let alreadyTried = candidate == model || candidate == declinedModel
        let shouldRetry = !anotherModelWontHelp && !alreadyTried
        let fallback = shouldRetry ? candidate : nil

        let notice = RefusalNotice(
            declinedBy: declinedModel,
            category: category,
            explanation: response.refusal?.explanation,
            answeredBy: fallback
        )
        rememberDeclinedPrompt(notice)
        if let fallback { model = fallback }
        return notice
    }

    private func rememberDeclinedPrompt(_ notice: RefusalNotice) {
        lock.lock(); defer { lock.unlock() }
        _lastRefusal = notice
        if _declined == nil {
            _declined = DeclinedRequest(promptIndex: _runPromptIndex, modelBefore: _model)
        }
    }

    /// Takes the prompt a model declined in the last run out of the
    /// conversation, with everything after it, and goes back to the model
    /// the run started on. Every request resends the whole conversation, so
    /// a declined prompt left in it can get later prompts declined too.
    ///
    /// Returns false when there is nothing to remove: no model declined in
    /// the last run, a new run has started, or a compaction has since
    /// folded the prompt into a summary.
    public func removeDeclinedRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let declined = _declined, declined.promptIndex < _session.messages.count else { return false }
        let before = _session.messages
        _session.messages.removeSubrange(declined.promptIndex...)
        recordRewrite(.declinedPromptRemoved, before: before)
        if _model != declined.modelBefore {
            record(.modelChanged(from: _model, to: declined.modelBefore))
        }
        _model = declined.modelBefore
        _declined = nil
        _lastRefusal = nil
        // The next model call reports the new size.
        _contextTokens = 0
        return true
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
            errorMessage: errorMessage,
            refusal: _lastRefusal
        )
    }

    private func finish(_ continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation, _ result: AgentResult) {
        if let dropped = takeSteering() {
            let note = AgentEvent.informational("Not delivered: \(dropped)")
            emit(note)
            continuation.yield(note)
        }
        record(.runFinished(result))
        emit(.result(result))
        continuation.yield(.result(result))
        continuation.finish()
    }

    // MARK: Tools

    /// The registry's tools plus the ones the loop itself provides. The order
    /// never changes between turns, so the request prefix stays cacheable.
    public var toolDefinitions: [ToolDefinition] {
        var definitions = tools.definitions
        if options.subAgents { definitions.append(Self.taskDefinition) }
        if options.compaction != nil { definitions.append(Self.rememberDefinition) }
        return definitions
    }

    /// Run each requested tool, collecting results in call order.
    ///
    /// Tools run one after another, for predictability: an edit and a test
    /// run must not overlap. The exception is several `task` calls in one
    /// turn: sub-agents only report back, so they run at the same time
    /// (after the turn's other calls).
    /// `progress` receives events produced while a tool runs (sub-agents).
    private func runTools(_ toolCalls: [ToolCall], progress: (AgentEvent) -> Void) async -> [ToolCallResult] {
        let runsTasksTogether = toolCalls.filter(isTaskCall).count > 1
        var resultsByIndex: [Int: ToolCallResult] = [:]
        for (index, call) in toolCalls.enumerated() {
            if runsTasksTogether && isTaskCall(call) { continue }
            let startedAt = Date()
            let result = await runTool(call, progress: progress)
            recordToolRun(call, result: result, startedAt: startedAt, durationMS: millisecondsSince(startedAt))
            resultsByIndex[index] = result
        }
        if runsTasksTogether {
            let tasks = toolCalls.enumerated().filter { isTaskCall($0.element) }.map { (index: $0.offset, call: $0.element) }
            for (index, result) in await runSubAgentsTogether(tasks, progress: progress) {
                resultsByIndex[index] = result
            }
        }
        return toolCalls.indices.compactMap { resultsByIndex[$0] }
    }

    private func isTaskCall(_ call: ToolCall) -> Bool {
        options.subAgents && call.name == Self.taskDefinition.name
    }

    private func recordToolRun(_ call: ToolCall, result: ToolCallResult, startedAt: Date, durationMS: Int) {
        let run = ToolRunRecord(
            callID: call.id,
            name: call.name,
            startedAt: startedAt,
            durationMS: durationMS,
            outputChars: result.content.count,
            isError: result.isError
        )
        record(.toolRun(run))
    }

    private func runTool(_ call: ToolCall, progress: (AgentEvent) -> Void) async -> ToolCallResult {
        let isRemember = options.compaction != nil && call.name == Self.rememberDefinition.name
        if isTaskCall(call) {
            let outcome = await runSubAgent(call, budgetShare: 1, progress: progress)
            if let usage = outcome.usage { recordUsage(usage, helper: true) }
            return outcome.result
        }
        if isRemember {
            let note = call.arguments.objectValue?["note"]?.stringValue ?? ""
            if note.isEmpty {
                return ToolCallResult(callID: call.id, name: call.name, content: "missing string argument 'note'", isError: true)
            }
            _notes.append(note)
            record(.noteSaved(note))
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
        what the answer should contain, and pass what you already know as context so it \
        doesn't read the same files again. Several task calls in one turn run at the same time.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The job: what to find or do, and what the answer should contain."),
                ]),
                "context": .object([
                    "type": .string("string"),
                    "description": .string("What you already know that the job needs: findings, file paths and line numbers, what was ruled out. The sub-agent sees nothing else of this conversation."),
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

    /// What a sub-agent run gives back: the `task` result, and the usage
    /// to add to this session's totals (nil when the child never finished).
    /// The caller records the usage, so sub-agents running at the same time
    /// never write this loop's totals.
    struct SubAgentOutcome: Sendable {
        var result: ToolCallResult
        var usage: Usage?
    }

    /// At most this many sub-agents run at once.
    static let maxParallelSubAgents = 4
    /// A sub-agent's answer joins this conversation and is resent with every
    /// later request, so a runaway answer is cut to head and tail.
    static let maxSubAgentAnswerChars = 24_000

    static let subAgentBrief = """
    You are a sub-agent. Only your final answer goes back to the agent that started you; it \
    doesn't see your tool calls or their output. Answer exactly what the job asks: findings \
    first, with path:line references and the commands or data that back them, then anything \
    you couldn't verify. Be concise.
    """

    /// The child's first message: the brief, then the parent's context, then
    /// the job. The brief comes first so sub-agents share a request prefix.
    static func subAgentPrompt(job: String, context: String?) -> String {
        var parts = [subAgentBrief]
        if let context, !context.isEmpty {
            parts.append("What the agent that started you already knows:\n\(context)")
        }
        parts.append("Your job:\n\(job)")
        return parts.joined(separator: "\n\n")
    }

    static func cappedSubAgentAnswer(_ text: String) -> String {
        guard text.count > maxSubAgentAnswerChars else { return text }
        let tailChars = maxSubAgentAnswerChars / 3
        let headChars = maxSubAgentAnswerChars - tailChars
        let omitted = text.count - maxSubAgentAnswerChars
        return text.prefix(headChars) + "\n[… \(omitted) characters of the sub-agent's answer left out …]\n" + text.suffix(tailChars)
    }

    /// Run a `task` call in a fresh loop. Its tool output never enters this
    /// conversation; only the final answer does. Its events are forwarded to
    /// `progress` as they happen, tagged with the call id. It may only spend
    /// its share of what is left of the budget (`budgetShare` children
    /// running together split it evenly).
    private func runSubAgent(_ call: ToolCall, budgetShare: Int, progress: (AgentEvent) -> Void) async -> SubAgentOutcome {
        func failure(_ message: String) -> SubAgentOutcome {
            SubAgentOutcome(result: ToolCallResult(callID: call.id, name: call.name, content: message, isError: true))
        }
        let fields = call.arguments.objectValue ?? [:]
        let job = fields["prompt"]?.stringValue ?? ""
        if job.isEmpty { return failure("missing string argument 'prompt'") }
        let prompt = Self.subAgentPrompt(job: job, context: fields["context"]?.stringValue)

        let child = AgentLoop(gateway: gateway, tools: tools, systemPrompt: systemPrompt, options: childOptions(budgetShare: budgetShare), cwd: cwd, journal: journal)
        child.journalParent = JournalParent(session: _session.id, callID: call.id)
        let childModel = options.helperModel ?? model
        child.model = childModel

        var childResult: AgentResult?
        do {
            for try await event in child.run(prompt: prompt) {
                if case .result(let result) = event { childResult = result }
                progress(.subAgent(SubAgentUpdate(callID: call.id, model: childModel, event: event)))
            }
        } catch {
            return failure("sub-agent failed: \(error)")
        }
        if Task.isCancelled { return failure("sub-agent cancelled") }
        guard let childResult else { return failure("sub-agent ended without a result") }

        guard childResult.isSuccess else {
            let reason = childResult.errorMessage ?? childResult.kind.rawValue
            var outcome = failure("sub-agent stopped: \(reason)")
            outcome.usage = childResult.usage
            return outcome
        }
        let answer = Self.cappedSubAgentAnswer(childResult.text ?? "")
        return SubAgentOutcome(result: ToolCallResult(callID: call.id, name: call.name, content: answer), usage: childResult.usage)
    }

    /// Run several `task` calls at the same time, at most
    /// `maxParallelSubAgents` at once. Their events reach `progress` live,
    /// through a stream, because `progress` may only be called from this task.
    private func runSubAgentsTogether(_ calls: [(index: Int, call: ToolCall)], progress: (AgentEvent) -> Void) async -> [(Int, ToolCallResult)] {
        let (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
        let budgetShare = min(calls.count, Self.maxParallelSubAgents)
        async let finished = runInBatches(calls, budgetShare: budgetShare, sink: sink)
        for await event in events { progress(event) }

        var results: [(Int, ToolCallResult)] = []
        for item in await finished.sorted(by: { $0.index < $1.index }) {
            if let usage = item.outcome.usage { recordUsage(usage, helper: true) }
            recordToolRun(item.call, result: item.outcome.result, startedAt: item.startedAt, durationMS: item.durationMS)
            results.append((item.index, item.outcome.result))
        }
        return results
    }

    private struct FinishedSubAgent: Sendable {
        var index: Int
        var call: ToolCall
        var outcome: SubAgentOutcome
        var startedAt: Date
        var durationMS: Int
    }

    private func runInBatches(
        _ calls: [(index: Int, call: ToolCall)],
        budgetShare: Int,
        sink: AsyncStream<AgentEvent>.Continuation
    ) async -> [FinishedSubAgent] {
        var finished: [FinishedSubAgent] = []
        var batchStart = 0
        while batchStart < calls.count {
            let batch = calls[batchStart..<min(batchStart + Self.maxParallelSubAgents, calls.count)]
            await withTaskGroup(of: FinishedSubAgent.self) { group in
                for (index, call) in batch {
                    group.addTask {
                        let startedAt = Date()
                        let outcome = await self.runSubAgent(call, budgetShare: budgetShare) { sink.yield($0) }
                        return FinishedSubAgent(index: index, call: call, outcome: outcome, startedAt: startedAt, durationMS: millisecondsSince(startedAt))
                    }
                }
                for await done in group { finished.append(done) }
            }
            batchStart += Self.maxParallelSubAgents
        }
        sink.finish()
        return finished
    }

    /// One model call, recorded in the journal whether it succeeds or not.
    /// Streams when `stream` is on, handing each partial update to `progress`.
    /// Returns the call's id too, so records can refer to it.
    private func callModel(
        _ request: ModelRequest,
        purpose: ModelCallRecord.Purpose,
        stream: Bool,
        progress: (AgentStreamUpdate) -> Void = { _ in }
    ) async throws -> (response: ModelResponse, callID: String) {
        let callID = UUID().uuidString
        let toolsID = recordTools(request.tools)
        let startedAt = Date()
        var firstChunkAt: Date?
        func callRecord(_ response: ModelResponse?, error: String?) -> ModelCallRecord {
            let summary = ModelCallRecord.Request(
                messageIDs: request.messages.map(\.id),
                toolsID: toolsID,
                model: request.model,
                provider: request.providerName,
                maxOutputTokens: request.maxOutputTokens,
                temperature: request.temperature,
                streamed: stream
            )
            let reply = response.map { response in
                ModelCallRecord.Response(
                    messageID: response.message.id,
                    stopReason: response.finishReason,
                    model: response.model,
                    provider: response.providerName,
                    replacedProvider: response.replacedProvider,
                    declinedBy: response.declinedBy
                )
            }
            let usage = response?.usage ?? .zero
            return ModelCallRecord(
                id: callID,
                purpose: purpose,
                request: summary,
                response: reply,
                usage: usage,
                costUSD: response == nil ? nil : cost(of: usage, purpose: purpose),
                startedAt: startedAt,
                firstChunkMS: firstChunkAt.map { Int(($0.timeIntervalSince(startedAt) * 1000).rounded()) },
                durationMS: millisecondsSince(startedAt),
                failedAttempts: response?.failedAttempts ?? [],
                wire: response?.wire,
                error: error
            )
        }

        do {
            let response = try await ask(request, stream: stream) { update in
                if firstChunkAt == nil { firstChunkAt = Date() }
                progress(update)
            }
            record(.modelCall(callRecord(response, error: nil)))
            return (response, callID)
        } catch {
            record(.modelCall(callRecord(nil, error: "\(error)")))
            throw error
        }
    }

    private func ask(_ request: ModelRequest, stream: Bool, progress: (AgentStreamUpdate) -> Void) async throws -> ModelResponse {
        guard stream else { return try await gateway.complete(request) }
        for try await chunk in gateway.stream(request) {
            switch chunk {
            case .thinkingDelta(let text): progress(.thinkingDelta(text))
            case .textDelta(let text): progress(.textDelta(text))
            case .toolCallStart(let call): progress(.toolCallStart(call))
            case .toolCallArguments(let id, let json): progress(.toolCallArgumentsDelta(id: id, partialJSON: json))
            case .finished(let response): return response
            }
        }
        try Task.checkCancellation()
        throw GatewayError.incompleteStream
    }

    /// A sub-agent's options: no further sub-agents, no streaming (only its
    /// result is shown), the helper's pricing when it runs on the helper
    /// model, and its share of what is left of the budget.
    private func childOptions(budgetShare: Int) -> LoopOptions {
        var child = options
        child.subAgents = false
        child.streamReplies = false
        if options.helperModel != nil {
            child.pricing = options.helperPricing ?? options.pricing
        }
        if let maxBudget = options.maxBudgetUSD {
            child.maxBudgetUSD = max(0, maxBudget - (totalCost ?? 0)) / Double(max(1, budgetShare))
        }
        return child
    }

    /// Add a model call's (or a sub-agent's) usage to the session totals.
    /// `helper` usage was spent on the helper model, if one is set.
    private func recordUsage(_ usage: Usage, helper: Bool) {
        _usage.accumulate(usage)
        if helper, options.helperModel != nil {
            _helperUsage.accumulate(usage)
        }
    }

    // MARK: Context size

    /// `report` gets the `.informational` note a compaction leaves; unlike
    /// the loop's other notes it says something the result won't.
    private func shrinkContext(report: (AgentEvent) -> Void) async throws {
        let clearsToolResults = options.keepToolResults != nil || options.keepToolResultChars != nil
        if clearsToolResults {
            let before = _session.messages
            _session.messages = ContextShrinking.clearingOldToolResults(
                before,
                keep: options.keepToolResults,
                maxChars: options.keepToolResultChars
            )
            recordRewrite(.toolResultsCleared, before: before)
        }
        guard let compaction = options.compaction, _contextTokens >= compaction.atContextTokens else { return }
        let compacted = try await compact(keepRecent: compaction.keepRecentMessages, report: report)
        if compacted > 0 {
            report(.informational("Compacted \(compacted) older messages into a summary."))
        }
    }

    /// Replace the older part of the conversation with a model-written
    /// summary, keeping the recent messages word for word.
    /// Returns how many messages were folded into the summary (0 when there
    /// was nothing old enough to compact).
    private func compact(keepRecent: Int, report: (AgentEvent) -> Void) async throws -> Int {
        let messages = _session.messages
        guard let cut = ContextShrinking.compactionCut(messages, keepRecent: keepRecent) else { return 0 }
        let systemMessages = messages.prefix { $0.role == .system }
        let older = messages[systemMessages.count..<cut]

        let summarizerPrompt = [
            Message(role: .system, text: ContextShrinking.summarizerInstructions),
            Message(role: .user, text: ContextShrinking.transcript(Array(older))),
        ]
        for message in summarizerPrompt {
            record(.message(message, appendedToContext: false))
        }
        let request = ModelRequest(
            model: options.helperModel ?? model,
            messages: summarizerPrompt,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
            mayFailOver: mayFailOver
        )
        let (response, callID) = try await callModel(request, purpose: .compaction, stream: false)
        record(.message(response.message, appendedToContext: false))
        recordUsage(response.usage, helper: true)
        try checkAnsweringProvider(response, report: report)

        let summary = ContextShrinking.summaryText(
            response.message.text,
            notes: _notes,
            files: ContextShrinking.fileLists(in: Array(older))
        )
        _session.messages = Array(systemMessages) + [Message(role: .user, text: summary)] + messages[cut...]
        recordRewrite(.compaction, before: messages, modelCallID: callID)
        // Message positions moved, and the declined prompt may be in the summary.
        _declined = nil
        // The next model call reports the new size; until then, don't compact again.
        _contextTokens = 0
        return older.count
    }

    // MARK: Journal

    /// Writes `session_started` and the messages the session began with
    /// (the system prompt), once, at the first run.
    private func startJournalIfNeeded() {
        guard let journal, !_journalStarted else { return }
        lock.lock()
        _journalStarted = true
        lock.unlock()
        let start = SessionStart(
            origin: journal.origin,
            cwd: cwd,
            model: model,
            options: journalOptions,
            parent: journalParent,
            resumed: _isRestored
        )
        record(.sessionStarted(start))
        if !_isRestored {
            recordAppended(_session.messages)
        }
    }

    private func record(_ record: JournalRecord) {
        guard let journal, _journalStarted else { return }
        journal.record(JournalEntry(session: _session.id, record: record))
    }

    /// Records messages that joined the end of the context.
    private func recordAppended(_ messages: some Sequence<Message>) {
        for message in messages {
            record(.message(message, appendedToContext: true))
        }
    }

    /// Records a change to the context that isn't a plain append: the new
    /// messages first, then which ids left, which came in, and the order
    /// that results. Nothing is written when nothing changed.
    private func recordRewrite(_ reason: ContextRewrite.Reason, before: [Message], modelCallID: String? = nil) {
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(_session.messages.map(\.id))
        let added = _session.messages.filter { !beforeIDs.contains($0.id) }
        let removed = before.map(\.id).filter { !afterIDs.contains($0) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        for message in added {
            record(.message(message, appendedToContext: false))
        }
        let rewrite = ContextRewrite(
            reason: reason,
            removed: removed,
            added: added.map(\.id),
            context: _session.messages.map(\.id),
            modelCallID: modelCallID
        )
        record(.contextRewrite(rewrite))
    }

    /// Records a tool set the first time it is sent; returns its id.
    private func recordTools(_ definitions: [ToolDefinition]?) -> String? {
        guard let definitions, journal != nil else { return nil }
        if let recorded = _recordedTools, recorded.definitions == definitions {
            return recorded.id
        }
        let id = UUID().uuidString
        _recordedTools = (definitions, id)
        record(.tools(id: id, definitions: definitions))
        return id
    }

    /// The options that shape a session's cost, for `session_started`.
    private var journalOptions: JSON {
        var fields: [String: JSON] = [
            "send_tools": .bool(options.sendTools),
            "sub_agents": .bool(options.subAgents),
            "stream_replies": .bool(options.streamReplies),
        ]
        if let maxTurns = options.maxTurns { fields["max_turns"] = .int(maxTurns) }
        if let turns = options.loopCheckAfterTurns { fields["loop_check_after_turns"] = .int(turns) }
        if let budget = options.maxBudgetUSD { fields["max_budget_usd"] = .double(budget) }
        if let tokens = options.maxOutputTokens { fields["max_output_tokens"] = .int(tokens) }
        if let temperature = options.temperature { fields["temperature"] = .double(temperature) }
        if let keep = options.keepToolResults { fields["keep_tool_results"] = .int(keep) }
        if let chars = options.keepToolResultChars { fields["keep_tool_result_chars"] = .int(chars) }
        if let compaction = options.compaction {
            fields["compaction"] = .object([
                "at_context_tokens": .int(compaction.atContextTokens),
                "keep_recent_messages": .int(compaction.keepRecentMessages),
            ])
        }
        if let model = options.helperModel { fields["helper_model"] = .string(model) }
        if let model = options.fallbackModel { fields["fallback_model"] = .string(model) }
        if let pricing = options.pricing { fields["pricing"] = pricing.json }
        if let pricing = options.helperPricing { fields["helper_pricing"] = pricing.json }
        return .object(fields)
    }

    /// One call's estimated cost, priced the way `totalCost` prices it.
    private func cost(of usage: Usage, purpose: ModelCallRecord.Purpose) -> Double? {
        guard let pricing = options.pricing else { return nil }
        let isHelperCall = purpose == .compaction && options.helperModel != nil
        let callPricing = isHelperCall ? (options.helperPricing ?? pricing) : pricing
        return callPricing.cost(of: usage)
    }

    // MARK: Cost

    /// A run with a budget cap stays on the gateway's preferred provider:
    /// `options.pricing` is that provider's price, so a fallback's tokens
    /// couldn't be counted against the cap. Its errors end the run instead.
    private var mayFailOver: Bool {
        let hasBudgetCap = options.maxBudgetUSD != nil && options.pricing != nil
        return !hasBudgetCap
    }

    /// Reports a reply from another provider than the last one: a fallback
    /// answered (see `Gateway.fallbackProviderNames`), or the preferred
    /// provider is back. A fallback's reply also ends a run with a budget
    /// cap, for a model that fails over despite `mayFailOver`.
    ///
    /// Which provider was meant is the gateway's word (`replacedProvider`),
    /// not worked out again here: it knows how it resolved the request.
    private func checkAnsweringProvider(_ response: ModelResponse, report: (AgentEvent) -> Void) throws {
        guard let answering = response.providerName else { return }
        let previous = _answeringProvider ?? response.replacedProvider ?? answering
        _answeringProvider = answering
        if answering != previous {
            let model = response.model.map { " (\($0))" } ?? ""
            report(.informational("Model provider \(answering)\(model) answered instead of \(previous)."))
        }
        if let preferred = response.replacedProvider, !mayFailOver {
            throw UnpricedFallbackError(provider: answering, preferred: preferred)
        }
    }

    /// Approximate US-dollar cost of the conversation so far, from per-token
    /// pricing if configured (nil otherwise). Helper-model usage is priced
    /// with `helperPricing` when that is set.
    public var totalCost: Double? {
        guard let pricing = options.pricing else { return nil }
        lock.lock(); defer { lock.unlock() }
        let helperPricing = options.helperPricing ?? pricing
        // Pricing is linear, so the main model's share is all minus the helper's.
        return pricing.cost(of: _usage) - pricing.cost(of: _helperUsage) + helperPricing.cost(of: _helperUsage)
    }

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }
}

/// A fallback provider answered a run that has a budget cap.
struct UnpricedFallbackError: Error, LocalizedError {
    var provider: String
    var preferred: String

    var errorDescription: String? {
        "\(preferred) couldn't serve the request and fallback provider \(provider) answered, "
            + "but the run's pricing is for \(preferred): stopped, since its budget cap can't be enforced"
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

    /// Pricing from `"input,output"` in USD per million tokens, the way
    /// providers publish prices, e.g. `"3,15"`. Nil if it doesn't parse.
    public init?(perMillionTokens text: String) {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let input = parts[0], let output = parts[1], input >= 0, output >= 0 else { return nil }
        self.init(inputPer1K: input / 1000, outputPer1K: output / 1000)
    }

    /// USD per 1,000 tokens, for the journal.
    var json: JSON {
        .object([
            "input_per_1k": .double(inputPer1K),
            "output_per_1k": .double(outputPer1K),
            "cache_read_per_1k": .double(cacheReadPer1K),
            "cache_write_per_1k": .double(cacheWritePer1K),
        ])
    }

    public func cost(of usage: Usage) -> Double {
        let input = Double(usage.inputTokens) * inputPer1K
        let output = Double(usage.outputTokens) * outputPer1K
        let cacheRead = Double(usage.cacheReadTokens) * cacheReadPer1K
        let cacheWrite = Double(usage.cacheWriteTokens) * cacheWritePer1K
        return (input + output + cacheRead + cacheWrite) / 1000
    }
}

extension Pricing {
    /// A price given per million tokens, as `LoopSettings` carries it.
    public init(_ price: TokenPrice) {
        self.init(inputPer1K: price.inputPerMillion / 1000, outputPer1K: price.outputPerMillion / 1000)
    }
}

extension LoopOptions {
    /// These options with `settings` applied: every setting that is set
    /// replaces its option; nil leaves the option as it is.
    ///
    /// How a program combines its own choices with the ones a person or a
    /// server made: build the options in code, then apply the settings.
    /// `compactAt` turns compaction on when it was off.
    public func applying(_ settings: LoopSettings) -> LoopOptions {
        var options = self
        if let tokens = settings.compactAt {
            let keepRecent = compaction?.keepRecentMessages ?? Compaction(atContextTokens: tokens).keepRecentMessages
            options.compaction = Compaction(atContextTokens: tokens, keepRecentMessages: keepRecent)
        }
        if let model = settings.helperModel { options.helperModel = model }
        if let price = settings.price { options.pricing = Pricing(price) }
        if let price = settings.helperPrice { options.helperPricing = Pricing(price) }
        if let budget = settings.maxBudgetUSD { options.maxBudgetUSD = budget }
        if let model = settings.fallbackModel { options.fallbackModel = model }
        if let stream = settings.stream { options.streamReplies = stream }
        return options
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
    /// From this many tool turns on, stop a run that keeps repeating the same
    /// tool calls with the same results (see `LoopDetector`). Nil = never check.
    public var loopCheckAfterTurns: Int?
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
    /// replaced with a one-line note. Nil = no count limit.
    public var keepToolResults: Int?
    /// Clear old tool results once the whole ones add up to more than this
    /// many characters, down to half of it. Nil = no size limit. Works with
    /// `keepToolResults`: whichever limit is passed first starts a clearing.
    public var keepToolResultChars: Int?
    /// Summarize long conversations. Also offers the model a `remember` tool
    /// whose notes survive the summary. Nil = never summarize.
    public var compaction: Compaction?
    /// Offer the model a `task` tool that runs a sub-agent in a fresh conversation.
    public var subAgents: Bool
    /// A cheaper model for sub-agents and summaries. Nil = the session's model.
    public var helperModel: String?
    /// Pricing for `helperModel`. Nil = priced like the main model.
    public var helperPricing: Pricing?
    /// Stream the main turn's reply, yielding `.stream` events as it
    /// arrives. Summaries and sub-agents never stream.
    public var streamReplies: Bool
    /// The model to ask when the session's model declines a request
    /// (`StopReason.refusal`); the session then stays on it. Nil = the
    /// provider's recommendation, if it sends one, else stop. Anthropic's
    /// API can do this itself (`ProviderConfig.serverFallbacks`).
    public var fallbackModel: String?

    public init(
        maxTurns: Int? = nil,
        loopCheckAfterTurns: Int? = 50,
        maxBudgetUSD: Double? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        sendTools: Bool = true,
        pricing: Pricing? = nil,
        keepToolResults: Int? = nil,
        keepToolResultChars: Int? = nil,
        compaction: Compaction? = nil,
        subAgents: Bool = false,
        helperModel: String? = nil,
        helperPricing: Pricing? = nil,
        streamReplies: Bool = true,
        fallbackModel: String? = nil
    ) {
        self.maxTurns = maxTurns
        self.loopCheckAfterTurns = loopCheckAfterTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.sendTools = sendTools
        self.pricing = pricing
        self.keepToolResults = keepToolResults
        self.keepToolResultChars = keepToolResultChars
        self.compaction = compaction
        self.subAgents = subAgents
        self.helperModel = helperModel
        self.helperPricing = helperPricing
        self.streamReplies = streamReplies
        self.fallbackModel = fallbackModel
    }
}
