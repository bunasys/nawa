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
///
/// Runs never overlap: a new run cancels the one still going (an
/// interrupted prompt whose tools are still unwinding) and waits for it to
/// end before it adds its prompt. State that other tasks read (`session`,
/// `usage`, `model`, the declined prompt) is written under `lock`; what only
/// the running run touches (turn count, loop check, notes) is not.
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
    /// A hook that gets every event the run's stream yields, in the same order.
    public let onEvent: (@Sendable (AgentEvent) -> Void)?
    /// Where the session is recorded (proposal 0005); nil records nothing.
    public let journal: (any SessionJournal)?
    /// For a sub-agent: the session and `task` call it works for, written
    /// into its `session_started` record.
    var journalParent: JournalParent?

    private let lock = NSLock()
    /// The session's id, which never changes; kept apart from `_session` so
    /// reading it needs no lock.
    private let sessionID: String
    private var _session: Session
    private var _usage: Usage
    private var _turnCounter: Int
    private var _loopDetector = LoopDetector()
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
    /// The id of the current run's prompt message. An id, not a position:
    /// clearing and compaction move messages around.
    private var _runPromptID = ""
    /// Whether this run already asked another model after a refusal. One
    /// retry per run, so two models recommending each other can't loop.
    private var _retriedAfterRefusal = false
    /// The last refusal of the current run, reported with its result.
    private var _lastRefusal: RefusalNotice?
    /// The provider that wrote the last reply, when the gateway said so.
    private var _answeringProvider: String?
    /// The prompt a model declined in the last run, kept until the next run
    /// so `removeDeclinedRequest` can take it out.
    private var _declined: DeclinedRequest?
    /// Messages from `steer`, waiting for the next model call.
    private var _steering: [String] = []
    /// Whether this run already took its one model call past `maxTurns` to
    /// answer a steer. One only, so steering can't lift the cap.
    private var _tookTurnCapGrace = false
    /// The run in progress (or the last one), so the next run can wait for it.
    private var _currentRun: Task<Void, Never>?
    /// Whether `session_started` is written; nothing is recorded before it.
    /// Behind its own lock: `record` reads it, also from code holding `lock`.
    private var _journalStarted = false
    private let journalLock = NSLock()
    /// Set by `init(restoring:)`: the session's messages are already in
    /// the journal, so starting it again must not record them twice.
    private var _isRestored = false
    /// The tool set last recorded, so an unchanged set isn't written again.
    private var _recordedTools: (definitions: [ToolDefinition], id: String)?

    private struct DeclinedRequest {
        var promptID: String
        /// The model the run started on, restored when the prompt is removed.
        var modelBefore: String?
    }

    /// The model id sent with each request; `nil` lets the gateway pick its
    /// configured or discovered default. Clients may switch it between turns
    /// (ACP `session/set_model`).
    public var model: String? {
        get { lock.withLock { _model } }
        set {
            let previous = lock.withLock {
                let previous = _model
                _model = newValue
                return previous
            }
            if previous != newValue {
                record(.modelChanged(from: previous, to: newValue))
            }
        }
    }

    /// The session this loop has been driving. Resumption: keep it, then run
    /// again with `run(prompt:continuing:true)`.
    public var session: Session {
        lock.withLock { _session }
    }

    /// Running token/cost accounting for the current conversation.
    public var usage: Usage {
        lock.withLock { _usage }
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
    ///   - onEvent: Observability hook; gets every event the run's stream
    ///     yields, in the same order.
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
        self.sessionID = sessionID
        self._session = session
        self._usage = .zero
        self._turnCounter = 0
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
        lock.withLock { !_steering.isEmpty }
    }

    /// Empties the steer queue: its messages as one text, or nil when empty.
    private func takeSteering() -> String? {
        lock.withLock {
            guard !_steering.isEmpty else { return nil }
            let text = _steering.joined(separator: "\n\n")
            _steering = []
            return text
        }
    }

    /// Run a prompt, streaming `AgentEvent`s.
    public func run(prompt: String, continuing: Bool = false) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let send: @Sendable (AgentEvent) -> Void = { [onEvent] event in
                onEvent?(event)
                continuation.yield(event)
            }
            let task = startRun { [self] in
                let result = await self.drive(prompt: prompt, continuing: continuing, send: send)
                self.finish(result, send: send)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts `body` once the previous run has ended, cancelling that run
    /// first. A cancelled run can still be unwinding (a shell command that
    /// ignores cancellation), and two runs writing the session, the turn
    /// count and the journal at once would interleave their messages.
    private func startRun(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = _currentRun
            previous?.cancel()
            let task = Task {
                await previous?.value
                await body()
            }
            _currentRun = task
            return task
        }
    }

    /// The run itself: turns until the model answers without tool calls or
    /// a limit stops it. Returns the run's result; `send` gets every event.
    private func drive(prompt: String, continuing: Bool, send: (AgentEvent) -> Void) async -> AgentResult {
        do {
            startJournalIfNeeded()
            // Emit the init event once per *conversation*, not per run.
            if !continuing {
                send(.initEvent(session))
            }
            let promptID = appendUser(prompt)
            record(.runStarted(promptMessageID: promptID, model: model))

            while true {
                if let maxTurns = options.maxTurns, _turnCounter >= maxTurns {
                    // A steer ("wrap up now") is most likely to come just
                    // as the turns run out, so it gets one call to answer.
                    let mayAnswerSteer = hasSteering && !_tookTurnCapGrace
                    guard mayAnswerSteer else {
                        send(.informational("Hit maxTurns (\(maxTurns)) — stopping."))
                        return result(.errorMaxTurns)
                    }
                    _tookTurnCapGrace = true
                }
                // Checked before the call, not after: a call made past the
                // cap would be paid for and then thrown away.
                if isOverBudget {
                    return result(.errorMaxBudgetUSD)
                }

                // 1. Ask the model, after trimming what it no longer needs
                // and adding what the caller steered in meanwhile.
                try await shrinkContext(report: send)
                deliverSteering(send: send)
                let response = try await askModel(send: send)
                if Task.isCancelled {
                    // Interrupted while the model answered: its tool calls
                    // must not start.
                    record(.message(response.message, appendedToContext: false))
                    throw CancellationError()
                }

                // A declined reply is dropped, partial text included:
                // it is not an answer. Ask the fallback model, if any.
                if response.finishReason == .refusal {
                    record(.message(response.message, appendedToContext: false))
                    let notice = recordRefusal(response)
                    record(.refusal(notice))
                    send(.refusal(notice))
                    if notice.answeredBy != nil { continue }
                    return result(.refused)
                }
                // Anthropic's server-side fallback already answered
                // in the model's place; say so, and keep the answer.
                if let declinedModel = response.declinedBy.first {
                    let notice = RefusalNotice(declinedBy: declinedModel, answeredBy: response.model)
                    rememberDeclinedPrompt(notice)
                    record(.refusal(notice))
                    send(.refusal(notice))
                }

                let toolCalls = response.message.toolCalls
                // A reply that crossed the cap is kept when it is the answer;
                // its tool calls aren't run, since their results would need
                // another paid call.
                if !toolCalls.isEmpty && isOverBudget {
                    record(.message(response.message, appendedToContext: false))
                    return result(.errorMaxBudgetUSD)
                }

                // 2. Persist the assistant turn and emit it.
                appendToContext([response.message])
                send(.assistant(AssistantUpdate(
                    text: response.message.text,
                    toolCalls: toolCalls,
                    usage: response.usage,
                    stopReason: response.finishReason,
                    sessionUsage: usage,
                    sessionCost: totalCost
                )))

                // 3. No tool calls → the run is done, unless the caller
                // steered in a message the model hasn't seen yet.
                if toolCalls.isEmpty {
                    guard hasSteering else {
                        return result(.success, text: response.message.text, stopReason: response.finishReason)
                    }
                    // Counted as a turn, so steering after every answer
                    // still reaches maxTurns.
                    _turnCounter += 1
                    continue
                }

                // 4. Execute the requested tools.
                _turnCounter += 1
                let results = await runTools(toolCalls, finishReason: response.finishReason, progress: send)
                // The context gets a pointer for output it already has;
                // events and the loop check see the real results.
                let contextResults = ContextShrinking.dedupingRepeatedResults(results, against: session.messages)
                appendToContext(contextResults.map(\.asMessage))
                send(.toolResults(results))
                // A cancelled run keeps what its finished tools did (so the
                // model won't redo an edit), then stops rather than asking
                // the model again.
                try Task.checkCancellation()

                let checkAfterTurns = options.loopCheckAfterTurns
                if let repeatedTools = _loopDetector.record(calls: toolCalls, results: results, checkAfterTurns: checkAfterTurns) {
                    let message = "Stopped after \(_turnCounter) tool turns: the same \(repeatedTools.joined(separator: ", ")) calls returned the same results \(LoopDetector.repeatLimit) times in the last \(LoopDetector.window) turns."
                    send(.informational(message))
                    return result(.errorDuringExecution, errorMessage: message)
                }
            }
        } catch {
            send(.informational("Loop error: \(error)"))
            return result(.errorDuringExecution, errorMessage: error.localizedDescription)
        }
    }

    /// Adds the steered messages, if any, to the context before the next call.
    private func deliverSteering(send: (AgentEvent) -> Void) {
        guard let steered = takeSteering() else { return }
        let message = Message(role: .user, text: steered)
        appendToContext([message])
        record(.steered(messageID: message.id))
        send(.informational("Steered: \(steered)"))
    }

    /// One turn's model call, with its usage counted and its provider checked.
    private func askModel(send: (AgentEvent) -> Void) async throws -> ModelResponse {
        let request = ModelRequest(
            model: model,
            messages: session.messages,
            tools: options.sendTools ? toolDefinitions : nil,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
            mayFailOver: mayFailOver,
            sessionID: sessionID,
            reasoningEffort: options.reasoningEffort
        )
        let (response, _) = try await callModel(request, purpose: .turn, helper: false, stream: options.streamReplies) { update in
            send(.stream(update))
        }
        recordUsage(response.usage, helper: false)
        lock.withLock { _contextTokens = response.usage.total }
        try checkAnsweringProvider(response, report: send)
        return response
    }

    /// Whether the session's estimated cost has reached `maxBudgetUSD`.
    private var isOverBudget: Bool {
        guard let maxBudget = options.maxBudgetUSD, let cost = totalCost else { return false }
        return cost >= maxBudget
    }

    /// Starts a run: appends the prompt and resets the turn counter and the
    /// loop check, so both apply to each prompt rather than the whole
    /// conversation. Returns the prompt message's id.
    private func appendUser(_ prompt: String) -> String {
        let promptMessage = Message(role: .user, text: prompt)
        let added: [Message] = lock.withLock {
            var added: [Message] = []
            // A run that ended between the model's tool calls and their
            // results (e.g. a crash, then a restore) left calls unanswered,
            // and providers refuse such a conversation.
            if let last = _session.messages.last, last.role == .assistant {
                added = last.toolCalls.map { Self.interruptedResult($0).asMessage }
            }
            added.append(promptMessage)
            _session.messages.append(contentsOf: added)
            _runPromptID = promptMessage.id
            _turnCounter = 0
            _loopDetector.reset()
            _lastRefusal = nil
            _declined = nil
            _retriedAfterRefusal = false
            _tookTurnCapGrace = false
            return added
        }
        recordAppended(added)
        return promptMessage.id
    }

    static func interruptedResult(_ call: ToolCall) -> ToolCallResult {
        ToolCallResult(callID: call.id, name: call.name, content: "interrupted by the user before it finished", isError: true)
    }

    /// Adds messages to the end of the context and records them.
    private func appendToContext(_ messages: [Message]) {
        lock.withLock { _session.messages.append(contentsOf: messages) }
        recordAppended(messages)
    }

    /// Replaces the context with a rewritten one and records what changed.
    private func rewriteContext(_ messages: [Message], reason: ContextRewrite.Reason, before: [Message], modelCallID: String? = nil) {
        lock.withLock { _session.messages = messages }
        recordRewrite(reason, before: before, after: messages, modelCallID: modelCallID)
    }

    // MARK: Refusals

    /// Notes a declined reply and picks the model to ask next: the
    /// configured `fallbackModel`, else the one the provider recommends.
    /// There is one retry per run: a refusal from the fallback is final,
    /// even when it recommends yet another model (or the first one back).
    private func recordRefusal(_ response: ModelResponse) -> RefusalNotice {
        let declinedModel = response.model ?? model
        let category = response.refusal?.category
        // These come from a prompt asking the model to write out its
        // reasoning; Anthropic recommends rewording, not another model.
        let anotherModelWontHelp = category == "reasoning_extraction"
        let candidate = options.fallbackModel ?? response.refusal?.recommendedModel
        let alreadyTried = candidate == model || candidate == declinedModel
        let shouldRetry = !anotherModelWontHelp && !alreadyTried && !_retriedAfterRefusal
        let fallback = shouldRetry ? candidate : nil

        let notice = RefusalNotice(
            declinedBy: declinedModel,
            category: category,
            explanation: response.refusal?.explanation,
            answeredBy: fallback
        )
        rememberDeclinedPrompt(notice)
        if let fallback {
            _retriedAfterRefusal = true
            model = fallback
        }
        return notice
    }

    private func rememberDeclinedPrompt(_ notice: RefusalNotice) {
        lock.withLock {
            _lastRefusal = notice
            if _declined == nil {
                _declined = DeclinedRequest(promptID: _runPromptID, modelBefore: _model)
            }
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
        guard let declined = _declined else { return false }
        guard let promptIndex = _session.messages.firstIndex(where: { $0.id == declined.promptID }) else { return false }
        let before = _session.messages
        _session.messages.removeSubrange(promptIndex...)
        recordRewrite(.declinedPromptRemoved, before: before, after: _session.messages)
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
            usage: usage,
            numTurns: _turnCounter,
            sessionID: sessionID,
            stopReason: stopReason,
            costEstimate: totalCost,
            errorMessage: errorMessage,
            refusal: lock.withLock { _lastRefusal }
        )
    }

    private func finish(_ result: AgentResult, send: (AgentEvent) -> Void) {
        if let dropped = takeSteering() {
            send(.informational("Not delivered: \(dropped)"))
        }
        record(.runFinished(result))
        send(.result(result))
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
    ///
    /// Every call gets a result. A call whose arguments are unusable gets an
    /// error instead of running; once the run is cancelled, the calls not
    /// yet started get an "interrupted" result.
    private func runTools(_ toolCalls: [ToolCall], finishReason: StopReason?, progress: (AgentEvent) -> Void) async -> [ToolCallResult] {
        var resultsByIndex: [Int: ToolCallResult] = [:]
        // A reply cut off at max_tokens stops inside its last call.
        let cutOffCallID = finishReason == .maxTokens ? toolCalls.last?.id : nil
        for (index, call) in toolCalls.enumerated() {
            resultsByIndex[index] = Self.rejectingUnusableArguments(call, isCutOff: call.id == cutOffCallID)
        }
        let runnable = toolCalls.enumerated().filter { resultsByIndex[$0.offset] == nil }
        let runsTasksTogether = runnable.filter { isTaskCall($0.element) }.count > 1

        for (index, call) in runnable {
            if runsTasksTogether && isTaskCall(call) { continue }
            if Task.isCancelled {
                resultsByIndex[index] = Self.interruptedResult(call)
                continue
            }
            let startedAt = Date()
            let result = await runTool(call, progress: progress)
            recordToolRun(call, result: result, startedAt: startedAt, durationMS: millisecondsSince(startedAt))
            resultsByIndex[index] = result
        }
        if runsTasksTogether {
            let tasks = runnable.filter { isTaskCall($0.element) }.map { (index: $0.offset, call: $0.element) }
            if Task.isCancelled {
                for (index, call) in tasks { resultsByIndex[index] = Self.interruptedResult(call) }
            } else {
                for (index, result) in await runSubAgentsTogether(tasks, progress: progress) {
                    resultsByIndex[index] = result
                }
            }
        }
        return toolCalls.indices.compactMap { resultsByIndex[$0] }
    }

    /// An error result for a call that must not run because its arguments
    /// can't be trusted, nil for a call that may run. Running a cut-off
    /// call would act on half its arguments (half a file written, say).
    static func rejectingUnusableArguments(_ call: ToolCall, isCutOff: Bool) -> ToolCallResult? {
        if isCutOff {
            let message = "not run: the reply reached the output token limit (max_tokens) while writing this call, so its arguments were cut off. Send the call again, in smaller pieces if it was long."
            return ToolCallResult(callID: call.id, name: call.name, content: message, isError: true)
        }
        // A call without arguments may arrive as null or an empty string.
        let hasNoArguments = call.arguments == .null || call.arguments.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        let isObject = call.arguments.objectValue != nil
        guard !isObject && !hasNoArguments else { return nil }
        let message = "not run: the arguments were not valid JSON (a JSON object was expected). Send the call again with valid JSON arguments."
        return ToolCallResult(callID: call.id, name: call.name, content: message, isError: true)
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
    /// its share of what is left of the budget (a turn's `budgetShare`
    /// `task` calls split it evenly).
    private func runSubAgent(_ call: ToolCall, budgetShare: Int, progress: (AgentEvent) -> Void) async -> SubAgentOutcome {
        func failure(_ message: String) -> SubAgentOutcome {
            SubAgentOutcome(result: ToolCallResult(callID: call.id, name: call.name, content: message, isError: true))
        }
        let fields = call.arguments.objectValue ?? [:]
        let job = fields["prompt"]?.stringValue ?? ""
        if job.isEmpty { return failure("missing string argument 'prompt'") }
        let prompt = Self.subAgentPrompt(job: job, context: fields["context"]?.stringValue)

        let child = AgentLoop(gateway: gateway, tools: tools, systemPrompt: systemPrompt, options: childOptions(budgetShare: budgetShare), cwd: cwd, journal: journal)
        child.journalParent = JournalParent(session: sessionID, callID: call.id)
        let childModel = options.helperModel ?? model
        child.model = childModel

        // What the child spent counts even when it didn't finish: it was
        // paid for, and the budget must see it.
        func failureAfterSpending(_ message: String) -> SubAgentOutcome {
            var outcome = failure(message)
            outcome.usage = child.usage
            return outcome
        }
        var childResult: AgentResult?
        do {
            for try await event in child.run(prompt: prompt) {
                if case .result(let result) = event { childResult = result }
                progress(.subAgent(SubAgentUpdate(callID: call.id, model: childModel, event: event)))
            }
        } catch {
            return failureAfterSpending("sub-agent failed: \(error)")
        }
        if Task.isCancelled { return failureAfterSpending("sub-agent cancelled") }
        guard let childResult else { return failureAfterSpending("sub-agent ended without a result") }

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
        // Split over every call, not just one batch: the children's spend is
        // counted only once all batches are done, so a later batch sees the
        // same remaining budget as the first.
        let budgetShare = calls.count
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
    /// Returns the call's id too, so records can refer to it. `helper` says
    /// whether it runs on the helper model; the record keeps that, so live
    /// totals, the call's cost and a replay all count it the same way.
    private func callModel(
        _ request: ModelRequest,
        purpose: ModelCallRecord.Purpose,
        helper: Bool,
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
                helper: helper,
                costUSD: response == nil ? nil : cost(of: usage, helper: helper),
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
    /// model (with the provider's effort), and its share of what is left of
    /// the budget.
    private func childOptions(budgetShare: Int) -> LoopOptions {
        var child = options
        child.subAgents = false
        child.streamReplies = false
        if options.helperModel != nil {
            child.pricing = options.helperPricing ?? options.pricing
            // The effort was chosen for the session's model; the helper may
            // not take the same words.
            child.reasoningEffort = nil
        }
        if let maxBudget = options.maxBudgetUSD {
            child.maxBudgetUSD = max(0, maxBudget - (totalCost ?? 0)) / Double(max(1, budgetShare))
        }
        return child
    }

    /// Add a model call's (or a sub-agent's) usage to the session totals.
    /// `helper` usage was spent on the helper model, if one is set.
    private func recordUsage(_ usage: Usage, helper: Bool) {
        let countsAsHelper = helper && options.helperModel != nil
        lock.withLock {
            _usage.accumulate(usage)
            if countsAsHelper {
                _helperUsage.accumulate(usage)
            }
        }
    }

    // MARK: Context size

    /// `report` gets the `.informational` note a compaction leaves; unlike
    /// the loop's other notes it says something the result won't.
    private func shrinkContext(report: (AgentEvent) -> Void) async throws {
        let clearsToolResults = options.keepToolResults != nil || options.keepToolResultChars != nil
        if clearsToolResults {
            let before = session.messages
            let cleared = ContextShrinking.clearingOldToolResults(
                before,
                keep: options.keepToolResults,
                maxChars: options.keepToolResultChars
            )
            // A cleared message gets a new id, so equal ids mean nothing changed.
            let clearedSomething = cleared.map(\.id) != before.map(\.id)
            if clearedSomething {
                rewriteContext(cleared, reason: .toolResultsCleared, before: before)
                // The context size that would trigger a compaction was
                // measured before this clearing; the next call reports the
                // new one, and compaction can decide then.
                return
            }
        }
        let contextTokens = lock.withLock { _contextTokens }
        guard let compaction = options.compaction, contextTokens >= compaction.atContextTokens else { return }
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
        let messages = session.messages
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
        let helperModel = options.helperModel
        var request = ModelRequest(
            model: helperModel ?? model,
            messages: summarizerPrompt,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
            mayFailOver: mayFailOver
        )
        // A helper model the provider doesn't serve (a typo, a model since
        // retired) must not end the run: summarize with the session's model
        // instead, and say so once in the events.
        let response: ModelResponse
        let callID: String
        var usedHelper = helperModel != nil
        do {
            (response, callID) = try await callModel(request, purpose: .compaction, helper: usedHelper, stream: false)
        } catch where helperModel != nil && !(error is CancellationError) && !Task.isCancelled {
            report(.informational("The helper model \(helperModel ?? "") couldn't summarize (\(error)); summarizing with the session's model instead."))
            request.model = model
            usedHelper = false
            (response, callID) = try await callModel(request, purpose: .compaction, helper: usedHelper, stream: false)
        }
        record(.message(response.message, appendedToContext: false))
        recordUsage(response.usage, helper: usedHelper)
        try checkAnsweringProvider(response, report: report)

        let summary = ContextShrinking.summaryText(
            response.message.text,
            notes: _notes,
            files: ContextShrinking.fileLists(in: Array(older))
        )
        let kept = ContextShrinking.redirectingOrphanedPointers(Array(messages[cut...]))
        let compacted = Array(systemMessages) + [Message(role: .user, text: summary)] + kept
        rewriteContext(compacted, reason: .compaction, before: messages, modelCallID: callID)
        // The next model call reports the new size; until then, don't compact again.
        lock.withLock { _contextTokens = 0 }
        return older.count
    }

    // MARK: Journal

    /// Writes `session_started` and the messages the session began with
    /// (the system prompt), once, at the first run.
    private func startJournalIfNeeded() {
        guard let journal else { return }
        let isFirstStart = journalLock.withLock {
            let isFirstStart = !_journalStarted
            _journalStarted = true
            return isFirstStart
        }
        guard isFirstStart else { return }
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
            recordAppended(session.messages)
        }
    }

    private func record(_ record: JournalRecord) {
        guard let journal, journalLock.withLock({ _journalStarted }) else { return }
        journal.record(JournalEntry(session: sessionID, record: record))
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
    private func recordRewrite(_ reason: ContextRewrite.Reason, before: [Message], after: [Message], modelCallID: String? = nil) {
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        let added = after.filter { !beforeIDs.contains($0.id) }
        let removed = before.map(\.id).filter { !afterIDs.contains($0) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        for message in added {
            record(.message(message, appendedToContext: false))
        }
        let rewrite = ContextRewrite(
            reason: reason,
            removed: removed,
            added: added.map(\.id),
            context: after.map(\.id),
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
        if let effort = options.reasoningEffort { fields["reasoning_effort"] = .string(effort) }
        if let pricing = options.pricing { fields["pricing"] = pricing.json }
        if let pricing = options.helperPricing { fields["helper_pricing"] = pricing.json }
        return .object(fields)
    }

    /// One call's estimated cost, priced the way `totalCost` prices it.
    /// A summary that fell back to the session's model is priced as that model.
    private func cost(of usage: Usage, helper: Bool) -> Double? {
        guard let pricing = options.pricing else { return nil }
        let isHelperCall = helper && options.helperModel != nil
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
        guard parts.count == 2, let input = parts[0], let output = parts[1] else { return nil }
        // `Double` also parses "inf" and "nan", which no price is.
        let isPrice = { (value: Double) in value.isFinite && value >= 0 }
        guard isPrice(input) && isPrice(output) else { return nil }
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
        if let effort = settings.effort { options.reasoningEffort = effort }
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
    /// How hard the session's model thinks on each turn, in place of the
    /// provider's `reasoningEffort`. Nil = the provider's. Summaries keep
    /// the provider's: they may run on a helper model that takes other words.
    public var reasoningEffort: String?

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
        fallbackModel: String? = nil,
        reasoningEffort: String? = nil
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
        self.reasoningEffort = reasoningEffort
    }
}
