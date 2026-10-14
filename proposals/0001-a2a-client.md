# 0001: A2A client, remote agents as sub-agents

- Status: Draft
- Depends on: none (it builds on the `AgentEvent.subAgent` events added with
  helper-model sub-agents)
- Spec: [A2A Protocol 1.0](https://a2a-protocol.org/latest/specification/)

## Summary

Let a Nawa session hand work to **remote agents** that speak the Agent2Agent
(A2A) protocol, the same way it hands work to local sub-agents today. Each
remote agent is set up per directory, like providers. It shows up as a
choice in the existing `task` tool, and its progress comes back as the
`AgentEvent.subAgent` events the REPL and ACP clients already show. A new
`AgentA2A` module holds the A2A wire types and the client.

## Motivation

The `task` tool can only start a copy of this same agent, with the same
tools and the same machine. A lot of useful agents live somewhere else and
are built by other teams: a research agent, an agent sitting next to a
private database, a company's internal review agent. A2A is the open
standard for calling such agents: discovery through an Agent Card,
long-running tasks, streaming progress, and cancellation. MCP doesn't cover
this. It exposes *tools*, while A2A exposes *agents* that plan for
themselves and keep their own state.

Helper-model sub-agents already gave us the right shape on our side. A
child's events are tagged with the parent's call id
(`SubAgentUpdate`), and a child's result becomes the `task` tool result. A
remote agent is one more kind of child.

## Goals

- Call a configured remote A2A agent from the `task` tool, and stream its
  progress live into the session's events.
- Find what the agent can do from its Agent Card
  (`/.well-known/agent-card.json`), and show it to the model in the `task`
  tool description.
- Support the JSON-RPC protocol binding with streaming (Server-Sent Events),
  and fall back to blocking `SendMessage` when the agent doesn't stream.
- Cancel the remote task when the parent run is cancelled.
- Authenticate with an HTTP bearer token or an API-key header, using the
  same `env:NAME` secrets as providers.

## Non-goals (for now)

- The gRPC and HTTP+JSON/REST bindings. The card's `supportedInterfaces`
  lets us choose JSON-RPC, and we already have a JSON-RPC envelope.
- Push notifications (webhooks). A CLI or editor session usually can't be
  reached over HTTP, and streaming covers our use.
- OAuth 2.0 / OpenID Connect flows, mTLS, signed Agent Cards
  (`signatures`), and the authenticated extended card.
- Files and binary parts going out. We send text, and JSON as `data` parts.
- Using A2A for *local* sub-agents. An in-process child loop is cheaper,
  simpler and already tested. A2A is only for agents in another process.

## Design

### Module layout

```
Sources/AgentA2A          // new: wire types + client. Depends on AgentCore, AgentJSONRPC.
  A2ATypes.swift          // Message, Part, Task, TaskStatus, TaskState, Artifact,
                          // StreamResponse, AgentCard (the fields we use), A2AError
  A2AClient.swift         // HTTP + SSE transport, method calls, version header
  RemoteA2AAgent.swift    // RemoteAgent conformance: A2A stream → AgentEvent
```

`AgentA2A` uses `URLSession` (as the gateway clients do) and has no
Hummingbird dependency, so the server (proposal 0002) can add its own target
on top without pulling a server stack into every client. The wire types live
here so client and server share one definition.

`AgentLoop` must not depend on A2A. It gets a small protocol in `AgentCore`
instead, so the loop treats every child the same way:

```swift
/// An agent the loop can hand a `task` to. Local child loops and remote
/// agents both conform; the loop only sees their events.
public protocol RemoteAgent: Sendable {
    /// Name the model uses in `task(agent:)`, unique per session.
    var name: String { get }
    /// One line for the `task` tool description (from the Agent Card).
    var summary: String { get }
    /// Run one job. Emits the same events a child loop does and ends with
    /// `.result`. Cancelling the consuming task cancels the remote work.
    func run(prompt: String) -> AsyncThrowingStream<AgentEvent, any Error>
}
```

`LoopOptions` gets `remoteAgents: [any RemoteAgent]`. `runSubAgent` picks
the local child loop when no `agent` is named, and the matching
`RemoteAgent` otherwise. Both paths go through the same code that forwards
events, records the result and builds the tool result, so the REPL, ACP
and the tests see no difference.

### The `task` tool

When `remoteAgents` is not empty, `task` gets an optional `agent` argument
whose `enum` lists the configured names, and the tool description gets one
line per agent:

```
agent: who does the job. Leave it out for a local sub-agent with your tools.
  - research: Finds and summarises papers (skills: literature-search, citations)
  - db-review: Reviews SQL migrations against the production schema
```

The list is built once when the session starts and doesn't change for the
rest of it, so the tool definitions stay byte-identical and the prompt cache
keeps hitting (see "Token costs" in AGENTS.md). Agent Cards fetched later
never change a running session's tools.

### Configuration

Remote agents are set up per directory in the config file next to
providers, so `nawa config` stays the only place users edit:

```json
{
  "providers": [ … ],
  "agents": [
    {
      "name": "research",
      "card": "https://research.example.com/.well-known/agent-card.json",
      "auth": { "bearer": "env:RESEARCH_AGENT_TOKEN" }
    }
  ]
}
```

- `card` is the Agent Card URL. A bare origin (`https://research.example.com`)
  means `<origin>/.well-known/agent-card.json`.
- `auth` is `{ "bearer": … }` or `{ "header": "X-API-Key", "value": … }`. Values
  accept literals or `env:NAME`, resolved the same way as
  `ProviderConfig.apiKey`.
- `NAWA_A2A_AGENTS` (a path to a JSON file with the same `agents` array)
  overrides the file, matching how `NAWA_GATEWAY_URL` overrides providers.

The Codable `RemoteAgentConfig` lives in `AgentGateway` next to
`ProviderConfig`, because `AgentConfigStore` owns the file. It is plain data
(name, URL, credentials) and has no A2A logic. The CLI gains
`nawa config agent add <name> <card-url>`, `nawa config agent list` and
`nawa config agent remove <name>`.

### Discovery

When a session starts (`serve` / `acp` / `repl`), the client fetches each
configured card **once**, in parallel, with a short timeout (5 s):

1. Decode the card. We read `name`, `description`, `version`, `capabilities`,
   `skills`, `supportedInterfaces`, `securitySchemes`, and ignore the rest.
2. Pick the first interface with `protocolBinding == "JSONRPC"` and
   `protocolVersion` `1.x`. If there is none, skip the agent with a warning
   naming what the card does offer (for example "only GRPC 1.0").
3. If the interface has a `tenant`, keep it and send it in every request.
4. Check `auth` against `securitySchemes`. Configured credentials that the
   card doesn't ask for are fine. If the card asks for a scheme we don't
   support (OAuth2, OIDC, mTLS), warn and skip the agent.

An agent that fails discovery is left out of the `task` enum for that
session, and the warning goes to stderr (never stdout in `acp` mode). One
broken remote agent never stops a session from starting.

### Calling an agent

For `task(agent: "research", prompt: …)`:

1. Build an A2A `Message`: `role: "ROLE_USER"`, a fresh `messageId` (UUID),
   and `parts: [{"text": prompt}]`. No `contextId` and no `taskId`, so every
   call starts a new task, just as a local sub-agent starts with an empty
   conversation.
2. If `capabilities.streaming` is true, POST `SendStreamingMessage` and read
   the SSE response. Every `data:` line is a JSON-RPC response whose
   `result` is a `StreamResponse` holding exactly one of `task`, `message`,
   `statusUpdate` or `artifactUpdate`.
3. Otherwise, POST `SendMessage` (blocking by default), which returns a
   `task` or a `message` once the work is finished or interrupted.

Every request sends `A2A-Version: 1.0`, `Content-Type: application/json`,
the auth header, and `Accept: text/event-stream` for streaming calls.

### Mapping A2A to Nawa events

`RemoteA2AAgent.run` turns the A2A stream into the same `AgentEvent`s a
child loop produces, so `SubAgentUpdate` works unchanged
(`model` = `"a2a:<name>"`):

| A2A | `AgentEvent` |
|---|---|
| First `task` (or the first event of any kind) | `.initEvent(Session(id: task.id, cwd: ""))` |
| `statusUpdate` in `TASK_STATE_WORKING` carrying a `message` | `.assistant(AssistantUpdate(text: <text parts>))` |
| `artifactUpdate` | gathered by `artifactId`, honouring `append` and `lastChunk`; no event |
| `message` (the agent answered without a task) | final text → `.result(.success)` |
| `TASK_STATE_COMPLETED` | `.result(.success)`, text = the artifacts' text parts, else the status message |
| `TASK_STATE_FAILED`, `TASK_STATE_REJECTED` | `.result(.errorDuringExecution)` with the status message |
| `TASK_STATE_CANCELED` | `.result(.errorDuringExecution)`, "remote task cancelled" |
| `TASK_STATE_INPUT_REQUIRED`, `TASK_STATE_AUTH_REQUIRED` | `.result` that ends the call; see below |

`data` parts become pretty-printed JSON in the text. `url` parts become
`[file: <filename> <url>]`. `raw` parts become a placeholder with the media
type and size. We never paste base64 into the conversation.

A remote result reaches the parent model just as a local one does: as the
`task` tool result, with the same head + tail cap and temp file for long
text (`CapturedOutput`).

**Interrupted states.** Version 1 doesn't continue interrupted tasks. The
tool result says the agent needs input, includes its question and the
task id, and suggests calling `task` again with a fuller prompt. Continuing
the same task (`taskId` follow-ups) is an open question below.

### Usage, cost and budget

A2A doesn't report token usage. The child's `AgentResult.usage` is
`.zero` and its `costEstimate` is nil, unless the remote agent puts usage
in the final status's `metadata` under the key `"nawa/usage"` (proposal
0002 makes Nawa do this). In that case, we record it like a local child's
usage, priced with `helperPricing`.

So `maxBudgetUSD` can't limit what an unknown remote agent spends. The
`task` description says so, and the session end logs one line per remote
call (agent, task id, duration).

### Cancellation and time limits

- When the parent run is cancelled, the SSE read stops and the client sends
  `CancelTask` for the task id, best effort and with a 5 s timeout.
  `TaskNotCancelableError` (-32002) and `TaskNotFoundError` (-32001) are
  ignored, because the task has already ended. The tool result is "sub-agent
  cancelled", as with local children.
- A stream that drops before a terminal state is resumed **once** with
  `SubscribeToTask` (it starts with the current `Task`, so nothing is lost),
  then with `GetTask` polling (every 2 s, capped at 2 min) if streaming
  fails again.
- Each call has an overall time limit (`timeout` in the agent's config,
  default 15 min), after which we cancel as above.

### Errors

JSON-RPC errors become tool results with `isError: true` and a readable
message. We never throw them up into the loop, because a failing remote
agent is something the model can work around:

| Code | Tool result text |
|---|---|
| -32001 TaskNotFound | "research: task <id> not found" |
| -32004 UnsupportedOperation | "research: <message>" |
| -32005 ContentTypeNotSupported | "research doesn't accept text input" |
| -32009 VersionNotSupported | "research doesn't support A2A 1.0" |
| HTTP 401 / 403 | "research rejected our credentials (check RESEARCH_AGENT_TOKEN)" |
| Network failure / time limit | "research is unreachable: <reason>" |

When an error's `data` contains a `google.rpc.ErrorInfo`, its `reason` is
added to the text.

## Security

- **Remote output is untrusted input.** A remote agent's answer goes into
  the conversation the same way tool output does, and it can try prompt
  injection. Its text is always wrapped as a tool result, never as a system
  or user message, and it can never add tools or change the session's
  configuration.
- **Prompts leave the machine.** Whatever the model writes in `prompt` (which
  may include code from the working directory) is sent to the remote agent.
  Agents are set up per directory and are off unless configured. The `task`
  description names each agent's host, so a client that shows tool calls
  makes the destination visible.
- **Transport.** `https` is required, except for `localhost` / `127.0.0.1` /
  `::1`. Certificates are checked by `URLSession` as usual.
- **Credentials** are sent only to the origin of the card they are
  configured for. Redirects to another origin drop the auth header. The
  interface URL taken from the card must have the same origin as the card
  URL, unless the config sets `"allowCrossOrigin": true`.
- **Size limits.** A single SSE event is capped (1 MiB), and so are the
  artifacts we gather (8 MiB) before truncating, so a misbehaving agent
  can't use up memory.

## Testing

- **Wire types:** round-trip the JSON examples from the spec (Agent Card,
  `SendMessage` request and response, `StreamResponse` variants, error
  objects), and check that unknown fields are ignored.
- **Event mapping:** feed `RemoteA2AAgent` a scripted `StreamResponse`
  sequence and check the `AgentEvent`s, artifact gathering (`append` and
  `lastChunk`), and each terminal and interrupted state.
- **Client over HTTP:** a small Hummingbird stub server in the test target
  serves a card and canned SSE streams. It covers streaming, blocking
  fallback, resuming with `SubscribeToTask` after a dropped stream,
  `CancelTask` on cancellation, auth headers, and dropping credentials on a
  cross-origin redirect.
- **Loop:** a fake `RemoteAgent` checks that `task(agent:)` forwards its
  events as `.subAgent` before the tool result, that tool definitions don't
  change after a card is fetched, and that an unknown agent name gives an
  error result.
- **End to end**, once 0002 lands: a Nawa A2A server on a loopback port
  with a `ScriptedModel`, called by a Nawa client session.

## Plan

Each step keeps `swift build` and `swift test` green.

1. `RemoteAgent` protocol in `AgentCore`, and `LoopOptions.remoteAgents`
   with the `task(agent:)` argument, tested with a fake agent. No A2A yet.
2. `AgentA2A` wire types and their tests.
3. `A2AClient`: JSON-RPC over HTTP, SSE parsing, the version header, auth,
   and errors, tested against the stub server.
4. `RemoteA2AAgent`: discovery, event mapping, cancellation, resuming.
5. Config (`RemoteAgentConfig`, `nawa config agent …`), wiring in `serve` /
   `acp` / `repl`, and updates to AGENTS.md.

## Open questions

1. **Follow-ups on interrupted tasks.** Should `task` take an optional
   `continue: <taskId>` so the model can answer `TASK_STATE_INPUT_REQUIRED`?
   It is cheap to add, but it means the client has to remember tasks across
   tool calls.
2. **Running calls in parallel.** Remote calls mostly wait on the network,
   so running several `task` calls from one turn at the same time pays off
   most here. That needs the loop's usage counters to be safe for
   concurrent use first (local sub-agents have the same problem).
3. **Multi-turn contexts.** Should repeated calls to the same agent within a
   session reuse a `contextId`, so it remembers earlier calls? That works
   better for chatty agents, but it means hidden state the parent can't see.
   Version 1 says no: every call is fresh, like local sub-agents.
4. **Config location.** Is the per-directory provider file the right home,
   or do remote agents belong in a user-wide list with per-directory
   opt-in?
