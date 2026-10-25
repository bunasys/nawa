import AgentCore
@testable import AgentTUI
import Synchronization
import Testing

/// After a model declines a prompt, the chat says so and asks whether to
/// keep the prompt in the context or remove it.
private let declined = RefusalNotice(declinedBy: "big", category: "cyber", explanation: "Could enable cyber harm.", answeredBy: "small")

private func refusedRun(_ notice: RefusalNotice = declined) -> [AgentEvent] {
    var final = result()
    final.refusal = notice
    var events: [AgentEvent] = [.stream(.textDelta("Sure, first")), .refusal(notice)]
    if notice.answeredBy != nil { events.append(turn("Fallback answer.", session: 10)) }
    events.append(.result(final))
    return events
}

/// How many times the chat asked to remove the declined request.
private final class Removals: Sendable {
    private let count = Mutex(0)
    func add() { count.withLock { $0 += 1 } }
    var total: Int { count.withLock { $0 } }
}

/// A session replaying `events` for the first prompt, counting removals.
private func session(_ events: [AgentEvent], removals: Removals) -> ChatSession {
    let runs = Mutex(0)
    return ChatSession(
        header: SessionHeader(directory: "~/p"),
        send: { prompt in
            let first = runs.withLock { count in count += 1; return count == 1 }
            let reply = first ? events : [turn("re \(prompt)"), .result(result())]
            return AsyncThrowingStream { continuation in
                for event in reply { continuation.yield(event) }
                continuation.finish()
            }
        },
        removeDeclinedRequest: {
            removals.add()
            return true
        }
    )
}

@Suite struct DeclinedRequestTranscriptTests {
    @Test func aRefusalDropsThePreviewAndSaysWhoAnswersInstead() {
        var transcript = Transcript()
        _ = transcript.submit("scan")
        _ = transcript.reduce(.stream(.textDelta("Sure, first")))
        let blocks = transcript.reduce(.refusal(declined))
        #expect(blocks == [
            .warning("big declined this request (cyber): Could enable cyber harm."),
            .note("small answers instead"),
        ])
        #expect(transcript.live.inFlight.text.isEmpty)
    }

    @Test func aRefusedRunSaysNoOtherModelAnswered() {
        var transcript = Transcript()
        _ = transcript.submit("scan")
        var final = result(.refused)
        final.refusal = RefusalNotice(declinedBy: "big", category: "cyber")
        #expect(transcript.reduce(.result(final)) == [.note("no other model answered; NAWA_FALLBACK_MODEL names one to retry on")])
    }
}

@Suite struct DeclinedRequestPlainTests {
    private func run(_ session: ChatSession, input: [String], echoPrompts: Bool) async -> String {
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        var lines = input[...]
        let chat = PlainChat(session: session, layout: Layout(columns: 200), echoPrompts: echoPrompts) { sink.text += $0 }
        await chat.run { lines.popFirst() }
        return sink.text
    }

    @Test func aPersonIsAskedAndRCanRemoveTheRequest() async {
        let removals = Removals()
        let output = await run(session(refusedRun(), removals: removals), input: ["scan", "r", "next"], echoPrompts: false)
        #expect(output.contains("? Continue this conversation on small, or remove the declined request from the context?"))
        #expect(output.contains("· removed the declined request and its replies from the context; next prompts go to big"))
        #expect(output.contains("● re next"))
        #expect(removals.total == 1)
    }

    @Test func enterKeepsTheRequest() async {
        let removals = Removals()
        let output = await run(session(refusedRun(), removals: removals), input: ["scan", ""], echoPrompts: false)
        #expect(output.contains("· kept; continuing on small"))
        #expect(removals.total == 0)
    }

    @Test func pipedInputIsNotTakenAsAnAnswer() async {
        let removals = Removals()
        let output = await run(session(refusedRun(), removals: removals), input: ["scan", "r"], echoPrompts: true)
        #expect(!output.contains("? "))
        #expect(output.contains("● re r"))
        #expect(removals.total == 0)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DeclinedRequestInlineTests {
    @Test func theQuestionWaitsForRAndIgnoresOtherKeys() async {
        let removals = Removals()
        let terminal = FakeTerminal(columns: 200)
        let chat = InlineChat(session: session(refusedRun(), removals: removals), terminal: terminal, color: false)
        let (keys, continuation) = AsyncStream<[Key]>.makeStream()
        let task = Task { await chat.run(keys: keys) }

        continuation.yield([.text("scan"), .enter])
        while !terminal.output.contains("enter: continue · r: remove") { await Task.yield() }
        // Typed before answering: ignored, not sent, not an answer.
        continuation.yield([.text("x"), .text("y")])
        continuation.yield([.text("r")])
        while !terminal.output.contains("removed the declined request") { await Task.yield() }
        continuation.yield([.text("/exit"), .enter])
        await task.value
        continuation.finish()

        let screen = terminal.screen.screen
        #expect(screen.contains("⚠ big declined this request (cyber): Could enable cyber harm."))
        #expect(screen.contains("· small answers instead"))
        #expect(screen.contains("● Fallback answer."))
        #expect(screen.hasSuffix("· removed the declined request and its replies from the context; next prompts go to big\n"))
        #expect(removals.total == 1)
    }

    @Test func enterKeepsTheRequestAndQueuedPromptsWaitForTheAnswer() async {
        let removals = Removals()
        let terminal = FakeTerminal(columns: 200)
        let chat = InlineChat(session: session(refusedRun(), removals: removals), terminal: terminal, color: false)
        let (keys, continuation) = AsyncStream<[Key]>.makeStream()
        let task = Task { await chat.run(keys: keys) }

        continuation.yield([.text("scan"), .enter])
        while !terminal.output.contains("enter: continue · r: remove") { await Task.yield() }
        continuation.yield([.enter])
        while !terminal.output.contains("kept; continuing on small") { await Task.yield() }
        continuation.yield([.text("next"), .enter])
        while !terminal.output.contains("re next") { await Task.yield() }
        continuation.yield([.text("/exit"), .enter])
        await task.value
        continuation.finish()

        #expect(terminal.screen.screen.contains("· kept; continuing on small\n\n› next\n● re next\n"))
        #expect(removals.total == 0)
    }
}
