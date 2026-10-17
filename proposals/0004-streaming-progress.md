# 0004: Show progress while the model thinks

- Status: Draft
- Depends on: 0003

## Summary

While a turn runs, `nawa repl` shows only `⠹ thinking · 40s`, and ACP
clients see nothing until the whole reply arrives. This proposal makes the
loop stream model replies and shows what comes in while it happens: the
reasoning text when the provider sends it, the reply as it is written, the
tool call being prepared, and a running output-token count. Nothing is
added to the conversation, the cost, or the prompt cache. The same events
reach ACP clients as `agent_thought_chunk` and `agent_message_chunk`. This
is the separate streaming change that proposal 0003 deferred (Decision 3).

## Motivation

Thinking models routinely work for 30 seconds to several minutes before
the first visible word. During that time, the user can't tell a model
that is reasoning from a request that has hung, so they interrupt turns
that were nearly done, or wait on ones that were dead.

The code already has half of what is needed, but none of it reaches the
user:

- `AgentLoop` only calls `gateway.complete` (`AgentLoop.swift`, the main
  turn and the helper summary call), so it never yields
  `AgentEvent.stream`.
- `Gateway.stream` collects every chunk before it yields the first one
  (`allChunks(of:)`), and drops errors: a stream that fails part-way just
  ends, with no `.finished` chunk.
- `AnthropicClient.stream` is not streaming. It calls `complete` and
  yields the result as a single chunk.
- `OpenAICompatibleClient.stream` really streams over SSE, but it ignores
  reasoning deltas (`reasoning_content` / `reasoning`). It doesn't ask for
  usage (`stream_options.include_usage`), so OpenAI reports none, and it
  leaves `finishReason` nil.
- `Transcript` ignores `.stream`. `ACPSession` would map `.textDelta` to
  `agent_message_chunk`, but it also sends the full text on `.assistant`,
  so turning on streaming would show every reply twice.

## Goals

- **Visible progress from the first byte**: a turn moves through
  *waiting → thinking → writing / preparing a tool*, and the status line
  says which, with the output tokens received so far.
- **The reasoning, while it happens**: when the provider sends reasoning
  text (Anthropic `thinking_delta`, `reasoning_content` from DeepSeek,
  vLLM, Kimi and LM Studio, `reasoning` from OpenRouter and Ollama), the
  last few lines are shown dimmed under the status line.
- **The reply, while it is written**: the reply's last lines are shown in
  the live region, then committed to scrollback once the turn ends, as
  they are today.
- **Same conversation**: a streamed turn leaves the session exactly as
  `complete` would, including Anthropic `thinking` blocks and their
  signatures (kept as `ContentBlock.opaque` and sent back unchanged).
- **ACP clients get it too**: reasoning as `agent_thought_chunk`, reply
  text as `agent_message_chunk`, with no text sent twice.

## Non-goals (for now)

- **Asking for reasoning.** Whether a model thinks, and how hard, is a
  request setting (Anthropic `thinking`, OpenAI `reasoning_effort`). This
  proposal shows the reasoning that arrives. Choosing the effort is a
  separate change. When a provider hides reasoning (encrypted or omitted
  thinking), the UI still shows the *thinking* phase, the time and the
  token count, just no text.
- **Keeping reasoning in scrollback.** Reasoning is progress, not part of
  the transcript (see Open questions).
- **Streaming in plain mode.** Line mode can't redraw, so `PlainChat`
  keeps printing whole blocks.
- **Streaming the helper model's calls** (compaction summaries). They
  stay on `complete`.

## Design

### What it looks like

```
› why does the build fail on Linux?

 ⠼ thinking · 23s · ~1.8k tokens · esc to interrupt
   …so the Glibc import is missing in Terminal.swift. But FileWalk
   already has the #if canImport guard, so the difference must be
   in how pthread_mutex_t is initialised on Linux.
╭──────────────────────────────────────────────────────╮
│ ›                                                    │
╰──────────────────────────────────────────────────────╯
```

then, once the reply starts:

```
 ⠦ writing · 41s · ~2.6k tokens · esc to interrupt
   Two things differ on Linux:
   1. `Darwin.write` doesn't exist there, so …
```

and while the model writes a tool call: `⠧ preparing shell · 44s`. When
the turn ends, the preview goes away, and the finished reply and tool calls
are committed to scrollback as they are today.

The preview shows at most **4 rows**, wrapped to the terminal width, and
always the newest text. The live region has to fit on screen, because
cursor-up stops at the top row (see 0003), so a long reply can't be shown
in full until it is committed. Reasoning is drawn dim, reply text plain.
Both go through the same control-character stripping as committed text.

The token count is an estimate (characters ÷ 4, shown as `~1.8k`).
Providers only report output tokens at the end of a reply. The real count
replaces the estimate in the footer when `.assistant` arrives, as it does
today.

### Domain (`AgentCore`, `AgentGateway`)

One new case each:

```swift
public enum StreamChunk {            // AgentGateway
    case thinkingDelta(String)       // new
    case textDelta(String)
    case toolCallStart(ToolCall)
    case toolCallArguments(id: String, partialJSON: String)
    case finished(ModelResponse)
}

public enum AgentStreamUpdate {      // AgentCore
    case thinkingDelta(String)       // new
    case textDelta(String)
    case toolCallStart(ToolCall)
    case toolCallArgumentsDelta(id: String, partialJSON: String)
}
```

The contract for every `LanguageModel.stream`: yield deltas as they
arrive, end with exactly one `.finished` that carries the same
`ModelResponse` `complete` would have returned, or throw. A stream that
ends without `.finished` is an error.

### Gateway

- **`Gateway.stream`** forwards chunks as they arrive and rethrows
  errors. `allChunks(of:)` is deleted.
- **`AnthropicClient.stream`** sends `"stream": true` and parses the
  Messages SSE events:

  | Event | Effect |
  |---|---|
  | `message_start` | input usage (fresh, cache read, cache write) |
  | `content_block_start` | `text`, `tool_use` (→ `.toolCallStart`), `thinking`, `redacted_thinking`, or anything newer: open block *n* |
  | `content_block_delta` | `text_delta` → `.textDelta`; `thinking_delta` → `.thinkingDelta`; `input_json_delta` → `.toolCallArguments`; `signature_delta` → appended to the block |
  | `content_block_stop` | close block *n* |
  | `message_delta` | `stop_reason`, output usage |
  | `ping` | ignored |
  | `error` | throw `GatewayError.httpError`-style with the message |

  Closed blocks are rebuilt as the JSON object the non-streaming API would
  have returned (`{"type":"thinking","thinking":…,"signature":…}` and so
  on). They then go through the **same** block parser `complete` uses, so
  thinking blocks become `.opaque` byte-for-byte as they do today, and
  block kinds we don't know yet are kept rather than dropped. The existing
  600 s timeout becomes an *idle* timeout between events, since a streamed
  reply may last longer than that in total.
- **`OpenAICompatibleClient.stream`** also reads `delta.reasoning_content`
  and `delta.reasoning` as `.thinkingDelta`, maps `finish_reason`, and
  sends `stream_options: {"include_usage": true}` so OpenAI reports usage
  (see Open questions for servers that reject it).

### Loop

`LoopOptions.streamReplies: Bool` (default `true`). When it's on, the
turn's model call becomes:

```swift
var response: ModelResponse?
for try await chunk in gateway.stream(request) {
    switch chunk {
    case .thinkingDelta(let t): yield(.stream(.thinkingDelta(t)))
    case .textDelta(let t):     yield(.stream(.textDelta(t)))
    case .toolCallStart(let c): yield(.stream(.toolCallStart(c)))
    case .toolCallArguments(let id, let json):
        yield(.stream(.toolCallArgumentsDelta(id: id, partialJSON: json)))
    case .finished(let r):      response = r
    }
}
guard let response else { throw GatewayError.incompleteStream }
```

Everything after that is unchanged: the same `.assistant` event, usage,
cost, budget check and session append. Cancelling works as it does today.
Ending the run's stream cancels the task, which cancels the `for try
await`, which ends the HTTP request through `onTermination`. A turn
interrupted mid-stream appends nothing.

Sub-agents run with `streamReplies` off. Their progress is already shown
step by step under the parent's `task` call, and forwarding every delta
of several parallel sub-agents through `.subAgent` would cost a lot of
events for little use.

`NAWA_STREAM=0` turns streaming off for `serve`, `acp` and `repl`. It is
there for providers whose streaming is broken.

### Terminal UI (`AgentTUI`)

`LiveState` gains what is in flight for the current model call:

```swift
public struct InFlight: Sendable, Hashable {
    public var thinking = ""        // newest ~2 KB only
    public var text = ""            // newest ~2 KB only
    public var preparing: ToolLabel?
    public var characters = 0       // for the ~token estimate
}
// LiveState.Phase: .waiting, .thinking, .writing, .preparingTool, .runningTools
```

`Transcript.reduce(.stream(…))` updates it and commits nothing. `.assistant`
clears it and commits as today. Only the tail of the text is kept, so each
frame lays out at most 2 KB, however long the reply is. Deltas can arrive
100 times a second, but the 33 ms frame coalescing from 0003 already
limits how often the screen is drawn, so no extra throttling is needed.

`Layout.status` gets the phase words and `~N tokens`.
`Layout.preview(_ inFlight:)` wraps the tail and returns its last 4
rows. `InlineChat` puts them between the status line and the running
tools. The 4-row cap is counted in the same screen-height budget as the
other live rows.

### ACP

`ACPSession` maps `.stream(.thinkingDelta)` to `agent_thought_chunk`
and `.stream(.textDelta)` to `agent_message_chunk` (as now). It records,
per turn, whether any text was streamed. If some was, the `.assistant`
event's text is **not** sent again. Its tool calls are sent as today.
`toolCallStart` stays unmapped: ACP's `tool_call` is sent when the call
is complete, with its arguments.

## Security

- Reasoning and reply text come from the model and may echo hostile
  input (file contents, web pages). The preview goes through the same
  sanitizer as committed text (0003): control characters and escape
  sequences are stripped before anything reaches the terminal.
- Reasoning is never written to disk or logs by this change. It ends up
  in the session only where it already does today: Anthropic thinking
  blocks, which the API requires us to send back.
- The SSE parsers must not grow without bound on a malicious or broken
  server: a single event line is capped (1 MB), and so is the accumulated
  tool-argument JSON for one call (the request's `max_tokens` already
  bounds a well-behaved reply).

## Testing

- **Anthropic SSE**: recorded fixtures for a thinking + text reply, a
  `tool_use` whose `input_json_delta`s split mid-token, `ping`s, a
  `redacted_thinking` block, and an `error` event mid-stream. The
  assembled `ModelResponse` is equal to what `complete` parses from the
  matching non-streaming body, including the `.opaque` thinking block.
- **OpenAI-compatible SSE**: `reasoning_content` and `reasoning` deltas,
  `include_usage` usage, `finish_reason`.
- **Gateway.stream** yields the first chunk before the upstream ends (a
  stub client that yields one chunk and then waits), and rethrows
  upstream errors.
- **Loop**: with `streamReplies`, a scripted streaming model produces
  `.stream` events and then the same `.assistant`, session and usage as
  with `complete`. A stream without `.finished` fails the run. Cancelling
  mid-stream appends nothing.
- **Transcript / Layout**: phases from deltas, the 2 KB tail, the
  4-row preview at width 20 and 80 with wide characters, control
  characters stripped, the preview cleared on `.assistant`, and the token
  estimate.
- **InlineChat** on `VirtualTerminal`: the preview shows while streaming,
  and once the turn ends, scrollback holds the reply once.
- **ACP**: thought chunks are sent, and the reply text isn't duplicated.
- Manual: a long Anthropic thinking turn and an Ollama reasoning model in
  `nawa repl`, and Zed over ACP.

## Plan

1. `Gateway.stream` passes chunks through and rethrows. Add
   `StreamChunk.thinkingDelta`, plus OpenAI-compatible reasoning, usage
   and finish reason. (Nothing calls `stream` yet, so nothing changes for
   users.)
2. Real SSE streaming in `AnthropicClient`, sharing the block parser
   with `complete`.
3. `LoopOptions.streamReplies`, `AgentStreamUpdate.thinkingDelta`,
   `NAWA_STREAM`. ACP thought chunks and no duplicated text.
4. `InFlight` in `Transcript`, the phases, the preview and the token
   estimate in `InlineChat`.
5. Update AGENTS.md (Token costs, the loop and gateway entries) and the
   README, and set this proposal's status.

## Open questions

1. **Keep a trace of the reasoning in scrollback?** This proposal drops
   the reasoning when the turn ends. One option is to commit a dim
   `· thought for 23s` line, so scrollback still shows where the time
   went. Another is an opt-in (`/thinking on`) that commits the full
   reasoning, dimmed. Proposed: the one-line summary always, full text
   not for now.
2. **Servers that reject `stream_options`.** Some OpenAI-compatible
   servers refuse unknown fields. Options are a per-provider flag in
   `ProviderConfig`, or retrying once without the field after a 400 that
   names it. Proposed: retry once, and remember the result for that
   provider for the rest of the process.
3. **Default on for ACP?** ACP clients expect chunks, and Zed shows
   thoughts. Proposed: on everywhere, with `NAWA_STREAM=0` as the way
   out.
