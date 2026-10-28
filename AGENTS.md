# AGENTS.md

This file follows the https://agents.md/ standard: it holds the instructions
for AI coding agents working in this repository. It is living documentation —
update it as the project evolves.

## Project overview

This SwiftPM package is **Nawa** (نواة, "kernel"), a **basic agent harness** (a "fundamental agent
runtime") in Swift. It embeds the agent loop described in the Claude Code Agent
SDK's agent-loop documentation, plus a configurable AI Gateway (OpenAI-compatible
chat completion API and the Anthropic Messages API, with multiple providers and auto model discovery), tool calls
and the MCP protocol, AGENTS.md loading per the agents.md standard, and the ACP
protocol (streamable HTTP + WebSocket, and stdio) as the way agents communicate
with users/clients.

The package follows **CUPID** principles: Composable, Unix-philosophy (do one
thing well), Predictable, Idiomatic, Domain-Based, plus Locality of Behavior.

## Layout

- `Sources/AgentCore` — domain model: `Message`, `Role`, `ContentBlock`,
  `ToolCall`, `ToolCallResult`, `Session`, `Usage`, `AgentEvent`, `AgentResult`,
  `JSON` (a small dependency-free JSON value), `ToolRegistry`. No external deps.
- `Sources/AgentGateway` — `LanguageModel` protocol, `OpenAICompatibleClient`
  (chat/completions + SSE streaming + tool calling; streamed reasoning
  becomes `StreamChunk.thinkingDelta`; asks for usage with
  `stream_options` and retries once without it on servers that refuse
  it), `AnthropicClient`
  (Messages API, streamed by `AnthropicStreamAssembler`, which rebuilds
  the blocks `complete` would get; keeps `thinking` blocks as
  `ContentBlock.opaque` and sends them back unchanged; reads refusals
  (`stop_details` → `ModelResponse.refusal`) and asks for server-side
  fallback (see Refusals below); authenticates with an API key or Workload Identity
  Federation via `WorkloadIdentityTokenSource` in `WorkloadIdentity.swift`,
  one cached token per process), `Gateway` with multiple
  providers (each `ProviderConfig.api` is `openai` or `anthropic`), fallback
  providers tried in order when one can't serve (`fallbackProviderNames`,
  `GatewayFailover` cooldowns; `ModelRequest.mayFailOver` opts out;
  `ModelResponse.providerName`/`replacedProvider` say who answered) and auto
  model discovery (`GET /v1/models`), `ProviderConfig` (its
  `requestTimeout`, 600 s by default, is how long a call waits before it
  fails over),
  `AgentConfigStore` (the per-directory config file written by `nawa config`).
- `Sources/AgentJSONRPC` — JSON-RPC 2.0 envelope shared by MCP and ACP.
- `Sources/AgentTools` — built-in tools: `ShellTool`, `ReadFileTool`,
  `EditFileTool`, `SearchTool` / `ListFilesTool` (ripgrep; without it,
  `FileWalk` gives the same results, .gitignore included), `CurrentTimeTool`,
  `EchoTool` (tests/demos), and `ToolSearchTool` / `CallToolTool`, which put
  large MCP tool sets behind two tools. Tools that touch files take the
  session's `workingDirectory`. `read_file` reads whole files (up to 2000
  lines) by default, since paging costs a model call per page. Long output is cut to head + tail with the
  full text saved to a temp file (`CapturedOutput`).
- `Sources/AgentInstructions` — `ProjectInstructions`: loads AGENTS.md from a
  directory, root-first / nearest-last so the closest file wins.
- `Sources/AgentLoop` — `AgentLoop`: the Runner/Event loop. Drives a session
  (init event → turns → tool execution → result), with maxTurns/maxBudget
  caps, usage accounting, and cost estimates. There is no turn cap by
  default: from turn 50 (`loopCheckAfterTurns`) `LoopDetector` stops a run
  whose last 10 turns repeat the same tool calls with the same results 3
  times. `steer(_:)` hands a running loop a message ("wrap up now"): it
  arrives as a user message after the current turn's tool results, and keeps
  a run going that would otherwise have ended (that call counts as a turn).
  A steer pending at `maxTurns` gets one more model call, once per run: a
  text answer is the run's `success`, tool calls still run and the run ends
  as `errorMaxTurns`. `LoopOptions` also turns on
  the token savers: `keepToolResults` (clear old tool output in batches),
  `compaction` (summarize older messages; adds a `remember` tool whose notes
  survive), `subAgents` (a `task` tool running a fresh child loop), and
  `helperModel` (cheaper model for both, priced with `helperPricing`). See
  `ContextShrinking.swift`. The main turn streams (`streamReplies`, on by
  default; `NAWA_STREAM=0` turns it off) and yields `.stream` events
  as the reply arrives; summaries and sub-agents don't stream. ACP sends
  reasoning as `agent_thought_chunk`. A sub-agent's events are forwarded live as
  `AgentEvent.subAgent(SubAgentUpdate)`, tagged with the parent's `task`
  call id; ACP shows them as `tool_call_update`s of that call. A sub-agent
  may only spend what is left of `maxBudgetUSD`. A declined reply is
  dropped and retried on `fallbackModel` (see Refusals below).
- `Sources/AgentTUI` — the `nawa repl` chat UI (proposal 0003; depends on
  `AgentCore` only, gets the agent as a `ChatSession` of closures).
  `Transcript` reduces `AgentEvent`s to committed `Block`s (append-only
  scrollback) plus `LiveState`, whose `InFlight` holds the newest part of
  a streaming reply for the live preview (proposal 0004; never committed:
  the turn commits whole, after a `· thought for Ns` note); `Layout` / `TranscriptLayout` turn them
  into `StyledLine`s for a width (display-width wrapping, never the last
  column, agent text sanitized of control characters); `ToolDisplay` has
  the one-line tool labels and result summaries. `ChatApp.run` picks the
  UI: `InlineChat` on a terminal, `PlainChat` otherwise (or `--plain`).
  `InlineChat` is one main-actor loop over keys, run events, ticks and
  resizes; Enter during a run queues, Esc / Ctrl-C interrupt (ending the
  run's stream cancels it). `InlineScreen` draws each frame as one string
  of relative moves (no alternate screen); `LiveRegion.swift` lays out the
  status line and the prompt box. `SlashCommand` (`/help`, `/clear`,
  `/cost`, `/tools`, `/exit`) runs the same in both UIs; `/clear` calls
  `ChatSession.reset`. After a refusal both UIs ask whether to keep the
  declined prompt (`DeclinedRequest.swift`). `Terminal` is the only file touching
  termios, ioctl and signals. Tests replay frames on `VirtualTerminal`.
  `PlainChat` is line mode
  (pipes, `TERM=dumb`); it turns Shift-Enter
  sequences (`ESC[27;2;13~`, `ESC[13;2u`) typed in cooked mode back into
  newlines.
- `Sources/AgentMCP` — `MCPClient`: spawns MCP servers, speaks JSON-RPC 2.0,
  exposes their tools.
- `Sources/AgentACP` — `ACPServer`: ACP over streamable HTTP and WebSocket on
  a single `/acp` endpoint (Hummingbird), `ACPStdioTransport` (ACP over
  stdin/stdout), plus the JSON-RPC frames. `ACPConnection` owns dispatch;
  each transport picks its `ACPOutboundRouting` (`.perSession` SSE streams
  for HTTP, `.singleStream` for stdio/WebSocket) and feeds raw frames to
  `handle(text:)`, which also answers unparseable ones.
- `Sources/nawa` — executable: `serve` (ACP server), `acp` (ACP over stdio),
  `repl` (interactive), and `config` (interactive per-directory provider setup,
  `ConfigCommand.swift`). `WakuCompatibility.swift` implements the Kimi Code
  CLI commands Waku calls, so Nawa can stand in for Kimi Code inside Waku.
  In `acp` mode stdout carries the protocol: never `print` there.
  `repl` builds a `ChatSession` from an `AgentLoop` (a fresh one on
  `/clear`) and hands it to `AgentTUI`.
- `Tests/` — Swift Testing suites, one per module.
- `proposals/` — design proposals for larger changes (`NNNN-title.md`; format
  and index in `proposals/README.md`). Read the relevant one before building
  a proposed feature, and update its status when it lands.

## Build & test

```
swift build
swift test
```

Nawa builds on macOS and Linux. Linux Foundation lacks a few Apple APIs,
so a couple of spots pick their implementation per platform; keep any new
platform-specific code just as small:
- `URLSession.streamBytes(for:)` (`AgentGateway/StreamingHTTP.swift`) is
  `bytes(for:)` on macOS and `ResponseByteStream` (delegate-based) on Linux.
  Its requests share one long-lived `StreamingSession` per owning session.
  Never create and release a `URLSession` per request on Linux: releasing
  one after HTTPS aborts the process (swift-corelibs-foundation#5203).
  That covers streaming only. A non-streaming HTTPS call made directly on
  a short-lived session still hits the bug, so keep the sessions that
  `complete` and model discovery use long-lived (`URLSession.shared` is).
- stdin in `ACPStdioTransport` is `FileHandle.bytes.lines` on macOS and
  `InputLines` (`DispatchIO`) on Linux.
Both Linux types build everywhere and are tested on macOS too. To run the
suite on Linux: `docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src swift:6.4 swift test`
(slow under emulation).

## CI and releases

GitHub Actions (`.github/workflows/`):
- `ci.yml` builds and tests on every push to `main` and every pull request:
  macOS (`macos-26`, its default Xcode) and Linux (`swift:6.4.1` container).
- `release.yml` publishes a release when a tag `vX.Y.Z` is pushed: it runs
  `ci.yml`, builds `nawa-X.Y.Z-macos-arm64.tar.gz` (ad-hoc signed, not
  notarized) and `nawa-X.Y.Z-linux-amd64.tar.gz` (fully static, Swift Static
  Linux SDK / musl), each with a `.sha256`, checks `--version` and an ACP
  `initialize` on both, then creates the GitHub release with generated notes
  (or adds the files to one that already exists, e.g. written by hand),
  then pushes the new formula to the Homebrew tap
  github.com/bunasys/homebrew-tap (`brew install bunasys/tap/nawa`).
  The formula comes from `scripts/homebrew-formula.sh`; pushing it needs
  the `HOMEBREW_TAP_TOKEN` secret (a fine-grained token with Contents
  read & write on the tap repo). Without it the job warns and skips.
  Run it by hand from the Actions tab for a dry run that publishes nothing.

To release: set the version in `ACPServerInfo.nawa`
(`Sources/AgentACP/ACPTypes.swift`; `nawa --version` prints it), commit,
push `main`, then `git tag -a vX.Y.Z -m "Nawa X.Y.Z" && git push origin vX.Y.Z`.
The run fails if the tag and the version differ.

The Static Linux SDK must match the container's compiler exactly: to move
to a newer Swift, change the `swift:` image in both workflows together with
`STATIC_SDK_URL` and `STATIC_SDK_CHECKSUM` in `release.yml` (verify the
SDK's `.sig` against swift.org's keys before taking its checksum).
`--static-swift-stdlib` alone is not enough: that binary still needs
`libcurl` on the user's machine.

## Running

```
# start the ACP server (streamable HTTP + WebSocket on :7878/acp)
swift run nawa serve

# interactive REPL against an OpenAI-compatible gateway
NAWA_GATEWAY_URL=https://api.openai.com/v1 \
NAWA_GATEWAY_API_KEY=$OPENAI_API_KEY \
NAWA_MODEL=gpt-4o-mini swift run nawa repl
```

## Model/provider configuration

The quickest path is `swift run nawa config` from the project directory: it
prompts for the API (`openai` or `anthropic`), a base URL and API key, lists the endpoint's models via
`GET /v1/models`, and saves the chosen provider + model for that directory in
`~/.config/nawa/config.json` (`$XDG_CONFIG_HOME` / `$NAWA_CONFIG_FILE`
honoured). Several providers can be saved per directory; `nawa config list`,
`nawa config use <name>`, and `nawa config remove <name>` manage them.
`serve` / `acp` / `repl` read that file for the current directory (ACP: the
session's `cwd`) unless `NAWA_GATEWAY_URL` is set (`NAWA_GATEWAY_API=anthropic`
selects the Anthropic wire API for that override).

Providers can also be configured in code through `ProviderConfig` + `Gateway`:
multiple OpenAI-compatible endpoints (OpenAI, Azure, Ollama, vLLM, LiteLLM,
LM Studio…) can be registered; the gateway routes to the active one and can
auto-discover models via `GET /v1/models` when none is configured. API keys
may be literals or `env:NAME` references. `Gateway` only routes: environment
fallbacks (`ANTHROPIC_WORKSPACE_ID`, the federation variables) are applied
once at load time with `GatewayConfig.withEnvironmentDefaults()`.

## Refusals

A model may decline a prompt (Anthropic's safety classifiers, e.g. the
`cyber` category, or OpenAI's `content_filter`): `StopReason.refusal`,
an HTTP 200, not an error. The loop drops that reply, partial text and
tool calls included, emits `AgentEvent.refusal(RefusalNotice)`, and asks
another model:
- On api.anthropic.com, `AnthropicClient` sends `fallbacks: "default"`
  (beta `server-side-fallback-2026-07-01`), so the server retries on the
  model Anthropic recommends for the category and the reply arrives with
  a `fallback` block (kept and sent back where it was; the declined
  model's tool calls and thinking before it are dropped). Set
  `ProviderConfig.serverFallbacks` to change the default; a 400 naming
  the field gets one retry without it.
- Otherwise the loop retries once on `NAWA_FALLBACK_MODEL`
  (`LoopOptions.fallbackModel`), or on the provider's
  `recommended_model`, and the conversation stays on that model.
  `reasoning_extraction` refusals are not retried: the prompt needs rewording.
No answer ends the run as `AgentResultKind.refused` (ACP: `refusal`).
`AgentResult.refusal` marks a run that had one; the repl then asks to keep
the prompt or remove it with `AgentLoop.removeDeclinedRequest`, which also
returns to the original model. A declined prompt left in the context is
resent with every request and can get later prompts declined too.

## Token costs

Every turn resends the whole conversation, so keep its prefix stable:
`AnthropicClient` sets prompt-cache breakpoints on the last tool, the system
prompt and the newest message; OpenAI caches stable prefixes on its own.
Don't put changing values (dates, file lists) in the system prompt, keep the
tool order fixed, and rewrite old messages only in large batches. `Usage`
keeps cache reads/writes apart from fresh input; `Pricing` prices them.
`NAWA_HELPER_MODEL` sets the helper model for `serve` / `acp` / `repl`;
`NAWA_PRICE` and `NAWA_HELPER_PRICE` (`"input,output"` USD per million
tokens) turn on cost estimates for the main and helper models.
`NAWA_MAX_BUDGET_USD` stops a prompt once the session's estimated cost
reaches it (needs `NAWA_PRICE`).
Streaming costs nothing extra: the reply is the same, it just arrives
in pieces. OpenAI-compatible streams only report usage when asked with
`stream_options.include_usage`, so keep that in the request (servers
that refuse it get one retry without it, and then no usage).

## Working with this repo (guidance for agents)

- Keep modules focused: each target in `Sources/` does one thing well.
- Domain types live in `AgentCore`; transports only ever speak `JSONRPCMessage`
  and domain types — never Thread/process primitives.
- Follow the Locality of Behavior principle: keep related code together, behaviors
  adjacent to the data they operate on.
- When adding a tool, add its test in the matching test suite.
- Commands: build with `swift build`, test with `swift test`. Both must stay
  green before committing.
- `origin` is the public repo github.com/bunasys/nawa. Push only `main`
  (`git push origin main`), never `--all` / `--mirror`: local
  `refs/waku/*` snapshots are not meant to be published.
- Never commit secrets: API keys go in environment variables or `env:NAME`
  references, never in tracked files. Before pushing, scan the outgoing
  commits (`git log -p origin/main..main`) for keys.
