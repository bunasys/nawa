# 0002: A2A server, Nawa as a remote agent

- Status: Draft
- Depends on: 0001 (shares the `AgentA2A` wire types)
- Spec: [A2A Protocol 1.0](https://a2a-protocol.org/latest/specification/)

## Summary

Make a Nawa agent callable by *other agents* over A2A. `nawa serve --a2a`
publishes an Agent Card at `/.well-known/agent-card.json` and serves the
A2A JSON-RPC binding at `/a2a`, with streaming over Server-Sent Events,
on the same Hummingbird server as ACP. Each A2A context is backed by one
Nawa session (`AgentLoop`), and each A2A task is one run of that session.
The loop's `AgentEvent`s become A2A status and artifact updates. A new
`AgentA2AServer` module does the work, and it reuses the wire types from
0001.

## Motivation

ACP connects Nawa to *people*, through editors and clients. Other agents
(an orchestrator, a CI bot, another team's assistant, or another Nawa
using 0001) have no standard way in. With A2A they can find Nawa, give it a
job, watch its progress, cancel it, and fetch the result later, without a
Nawa-specific integration.

It also completes 0001. A Nawa client calling a Nawa server is the
simplest real end-to-end test of both, and it lets a session on a laptop
hand work to a Nawa running next to a codebase or a dataset elsewhere.

## Goals

- A valid Agent Card that declares the JSON-RPC binding at A2A version 1.0,
  `capabilities.streaming: true`, the auth scheme, and configured skills.
- These methods: `SendMessage` (blocking and `returnImmediately`),
  `SendStreamingMessage`, `GetTask` (with `historyLength`), `ListTasks`,
  `CancelTask`, `SubscribeToTask` (several subscribers per task).
- Multi-turn conversations: messages that share a `contextId` continue the
  same Nawa session.
- The spec's error codes and `google.rpc.ErrorInfo` details.
- Bearer-token authentication, required whenever A2A is on.

## Non-goals (for now)

- The gRPC and HTTP+JSON/REST bindings.
- Push notifications. `capabilities.pushNotifications` is false, and the
  `*TaskPushNotificationConfig` methods return
  `PushNotificationNotSupportedError` (-32003).
- The extended Agent Card. `capabilities.extendedAgentCard` is false, so
  `GetExtendedAgentCard` returns `UnsupportedOperationError` (-32004).
- File inputs other than text. `raw` / `url` parts that aren't `text/*`
  are rejected with `ContentTypeNotSupportedError` (-32005).
- Keeping tasks across restarts. The task store lives in memory.
- Letting A2A callers choose the working directory or add MCP servers (see
  Security).
- Streaming the final answer token by token (`.stream` deltas as appended
  artifact chunks). It could come later. Version 1 sends text per turn.

## Design

### Module layout

```
Sources/AgentA2AServer        // new. Depends on AgentA2A, AgentCore, AgentJSONRPC,
                              // AgentLoop, Hummingbird.
  A2ARoutes.swift             // card, POST /a2a, SSE responses, auth, version check
  A2ADispatcher.swift         // method → handler, errors as JSON-RPC
  A2ATaskStore.swift          // actor: tasks, contexts, event logs, subscribers, expiry
  A2ATaskRun.swift            // runs one task on an AgentLoop; AgentEvent → StreamResponse
  A2AAgentCard.swift          // builds the card from configuration
```

Following AGENTS.md, the dispatcher and the task store only deal in
`JSONRPCMessage` and domain types. HTTP and SSE stay in `A2ARoutes`, just
as `ACPConnection` is kept apart from `ACPServer`.

**One server, one port.** `ACPServer.buildApplication()` builds its own
router today. We add a hook so other modules can add routes to it:

```swift
public protocol RouteProvider: Sendable {
    func register(on router: Router<BasicRequestContext>)
}
// ACPServer(factory:, configuration:, extraRoutes: [any RouteProvider])
```

`nawa serve --a2a` passes an `A2ARoutes`. ACP's own routes don't change.

**Sessions.** The server makes loops through a factory like
`ACPSessionFactory`:

```swift
public protocol A2ASessionFactory: Sendable {
    func makeLoop(contextID: String) async throws -> AgentLoop
}
```

The `nawa` executable's `HarnessSessionFactory` adopts it. It uses the
working directory set for A2A, that directory's providers and
AGENTS.md, the built-in tools, and `defaultLoopOptions()`, so sub-agents,
the helper model and compaction work as they do in the REPL.

### Configuration

```
nawa serve --a2a \
  [--a2a-cwd <dir>]            # working directory for A2A sessions (default: cwd)
  [--public-url <https://…>]   # base URL written into the Agent Card
  [--host 127.0.0.1] [--port 7878]
```

| Environment | Meaning |
|---|---|
| `NAWA_A2A_TOKEN` | Required. The bearer token callers must send (`env:` style values are allowed in the config file). |
| `NAWA_A2A_NAME`, `NAWA_A2A_DESCRIPTION` | The card's `name` / `description` (default "Nawa", "A coding agent working in <dir>"). |
| `NAWA_A2A_SKILLS` | Path to a JSON array of `AgentSkill` objects. Default: one generic skill. |
| `NAWA_A2A_MAX_TASKS` | How many tasks may run at once (default 4). |

The same settings can go in the per-directory config file under `"a2a"`.

### Agent Card

`GET /.well-known/agent-card.json` needs no auth and returns:

```json
{
  "name": "Nawa",
  "description": "A coding agent working in /srv/project",
  "version": "<nawa version>",
  "supportedInterfaces": [
    { "url": "<public-url>/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0" }
  ],
  "capabilities": { "streaming": true, "pushNotifications": false, "extendedAgentCard": false },
  "securitySchemes": {
    "bearer": { "httpAuthSecurityScheme": { "scheme": "Bearer" } }
  },
  "securityRequirements": [ { "schemes": { "bearer": { "list": [] } } } ],
  "defaultInputModes": ["text/plain", "application/json"],
  "defaultOutputModes": ["text/plain"],
  "skills": [
    {
      "id": "coding",
      "name": "Coding agent",
      "description": "Reads, searches and edits files and runs shell commands in its project.",
      "tags": ["code", "shell", "files"]
    }
  ]
}
```

The security shapes follow the spec's examples (a `SecurityScheme` holds
exactly one of its scheme objects, and requirements map scheme names to
scope lists). The card comes from configuration only, never
from the conversation, and it doesn't change while the server runs. It is
served with `Cache-Control: max-age=300`.

### Requests

`POST /a2a` takes one JSON-RPC request:

1. **Auth.** Without `Authorization: Bearer <NAWA_A2A_TOKEN>`, the server
   answers HTTP 401 with `WWW-Authenticate: Bearer`. The comparison takes
   constant time.
2. **Version.** The `A2A-Version` header (or query parameter) must be
   `1.0` (`1.x`). Anything else, *including a missing header* (which the
   spec says means 0.3), gets `VersionNotSupportedError` (-32009) naming the
   supported version.
3. **Dispatch.** The method goes to a handler. An unknown method gets
   -32601, and bad params get -32602 with a `google.rpc.BadRequest` naming
   the field.
4. **Response.** Unary methods answer `application/json`.
   `SendStreamingMessage` and `SubscribeToTask` answer
   `text/event-stream`, with one `data: {"jsonrpc":"2.0","id":…,"result":<StreamResponse>}`
   line per event, and the stream closes once the task reaches a terminal
   state.

If streaming is unavailable or `streaming` is false, the error is
`UnsupportedOperationError` (-32004). That can't happen while we declare
streaming, but the code checks the capability, not a constant.

### Contexts, tasks and sessions

| A2A | Nawa |
|---|---|
| `contextId` | one `AgentLoop` (a session and its conversation), created on first use |
| `taskId` | one `loop.run(prompt:)` in that context |
| `Message.parts` | the prompt: `text` parts joined, `data` parts as fenced JSON, `text/*` files inlined (up to a size limit) |

How messages are routed, following the spec's context rules:

- **No `taskId`, no `contextId`:** new context, new loop, new task.
- **`contextId` only:** new task in that context, so the conversation
  continues. If the context has a task still running, the request is
  rejected with `UnsupportedOperationError` "context <id> is busy with task
  <id>". The loop runs one prompt at a time, and queueing would hide
  ordering from the caller.
- **`taskId` of a terminal task:** `UnsupportedOperationError`, as the
  spec requires.
- **`taskId` of a non-terminal task:** Nawa never leaves a task waiting
  for input in version 1 (it has no approval prompts), so this only happens
  while a task is `WORKING`. It is rejected as busy.
- **`contextId` that doesn't match the task's context:** -32602, as the
  spec requires.
- **Unknown `taskId`:** `TaskNotFoundError` (-32001).

A task's `history` holds the user message and the agent's per-turn status
messages. `GetTask.historyLength` cuts it to the last N entries.

### Mapping Nawa events to A2A

`A2ATaskRun` reads `loop.run(prompt:)` and appends to the task's event
log. Every event is applied to the stored `Task` and sent to every
subscriber, in order:

| `AgentEvent` | A2A |
|---|---|
| task accepted | `task` with `TASK_STATE_SUBMITTED` (always the first event of a stream) |
| `.initEvent` | `statusUpdate` → `TASK_STATE_WORKING` |
| `.assistant` with text | `statusUpdate` (`WORKING`) with a `ROLE_AGENT` message holding that text |
| `.assistant` with tool calls | the same message, plus a `data` part `{"toolCalls":[{"name":…}]}` (names only; arguments can contain file contents) |
| `.subAgent` | `statusUpdate` (`WORKING`) with metadata `"nawa/subAgent": {"callId", "model"}` and the child's text, at most one per child turn |
| `.toolResults`, `.stream`, `.informational` | not forwarded (too large or too noisy for a remote caller) |
| `.result(.success)` | `artifactUpdate` (artifact `answer`, text part, `lastChunk: true`), then `statusUpdate` → `TASK_STATE_COMPLETED` |
| `.result` max turns / max budget | `statusUpdate` → `TASK_STATE_FAILED` with the reason in the message |
| `.result(.errorDuringExecution)` | `TASK_STATE_FAILED` with the provider's error message |

The final `statusUpdate` carries metadata `"nawa/usage"` (tokens split into
input, output, cache reads and cache writes, plus the cost estimate when
pricing is set). The 0001 client reads this to count remote spend. Other
clients ignore it.

### Blocking and non-blocking `SendMessage`

- **Default (blocking):** wait until the task reaches a terminal state, then
  return the full `Task` (status, artifacts, history cut by
  `historyLength`). If the HTTP connection closes first, the task keeps
  running and can be fetched with `GetTask`.
- **`returnImmediately: true`:** return the `SUBMITTED` / `WORKING` task
  at once. The caller then polls `GetTask` or uses `SubscribeToTask`.

### Cancellation

`CancelTask` cancels the Swift `Task` running the loop. It answers with
the task in `TASK_STATE_CANCELED`, and open streams get that final
`statusUpdate`. Cancelling a terminal task gets `TaskNotCancelableError`
(-32002). Cancelling twice is allowed, as the spec requires: the second
call returns the same cancelled task. A client that disconnects doesn't
cancel the task. Only `CancelTask` does.

### Task store

`A2ATaskStore` is an actor that holds:

- `tasks[id]`: the `Task` snapshot, its context id, its event log, and its
  subscriber continuations.
- `contexts[id]`: the `AgentLoop` and the running task's id, if any.

`SubscribeToTask` sends the current `Task` first and then new events.
Adding the subscriber and taking the snapshot happen in the same actor
call, so nothing falls in between, as the spec requires. A subscriber that
falls behind (more than 1,000 queued events) is disconnected rather than
blocking the run.

**Limits.** At most `NAWA_A2A_MAX_TASKS` running tasks. Beyond that,
`SendMessage` fails with `UnsupportedOperationError` "server busy". Terminal
tasks are kept for 1 h. Contexts unused for 1 h are dropped together with
their loop. `ListTasks` pages by creation time, newest first, using an
opaque page token.

### Errors

The JSON-RPC envelope from `AgentJSONRPC` carries the errors. `data` is
always an array with one `google.rpc.ErrorInfo`:

```json
{ "@type": "type.googleapis.com/google.rpc.ErrorInfo",
  "reason": "TASK_NOT_FOUND", "domain": "a2a-protocol.org",
  "metadata": { "taskId": "…" } }
```

| Code | Reason | When |
|---|---|---|
| -32001 | `TASK_NOT_FOUND` | unknown or expired task |
| -32002 | `TASK_NOT_CANCELABLE` | cancelling a terminal task |
| -32003 | `PUSH_NOTIFICATION_NOT_SUPPORTED` | any push-config method |
| -32004 | `UNSUPPORTED_OPERATION` | busy context, terminal task, server full, extended card |
| -32005 | `CONTENT_TYPE_NOT_SUPPORTED` | non-text file parts |
| -32009 | `VERSION_NOT_SUPPORTED` | `A2A-Version` isn't 1.x |

A model or provider failure is *not* a JSON-RPC error. The task ends in
`TASK_STATE_FAILED` with the message, the same way ACP reports failed
turns.

## Security

This is the riskiest part of the two proposals: **it gives a network caller
an agent that can run shell commands.**

- **Auth is required.** `--a2a` refuses to start without `NAWA_A2A_TOKEN`.
  There is no anonymous mode, even on loopback, because any local process
  or browser page can reach loopback.
- **Binding.** The default host stays `127.0.0.1`. Binding to anything else
  needs an explicit `--host`, and the server warns at startup if
  `--public-url` isn't `https` (TLS is meant to end at a reverse proxy).
- **Fixed working directory.** A2A callers can't choose `cwd`, add MCP
  servers or change the model. Those come from the server's configuration
  only. A caller gets exactly the agent the operator set up.
- **Browser requests.** `/a2a` sends no CORS headers, and it refuses requests
  that carry an `Origin` header unless that origin is allowed in the
  config. The card endpoint may allow any origin.
- **What callers see.** Tool arguments and tool output never leave the
  server (names only, see the mapping table). The final answer is whatever
  the model writes. Operators should treat everything in the working
  directory as readable by callers.
- **Abuse.** The concurrency limit, the task expiry and the per-task
  `maxTurns` / `maxBudgetUSD` (from `defaultLoopOptions`, which can be
  overridden in the `"a2a"` config) limit what one token holder can spend.
- **ACP has no auth today.** That is out of scope here, but sharing the
  server makes it worth a follow-up proposal.

## Testing

- **Agent Card:** the JSON validates against the card fields the spec
  requires, and the interface URL follows `--public-url`.
- **Dispatcher**, with no HTTP: every method's happy path, every error code
  in the table, the context routing rules, `historyLength`, and
  `ListTasks` paging.
- **Task run:** a `ScriptedModel` loop produces the expected
  `StreamResponse` sequence. That covers success, max turns, provider
  errors, sub-agent progress, and usage metadata.
- **Concurrency:** two subscribers see identical ordered streams. A late
  `SubscribeToTask` gets the current `Task` first. `CancelTask` during a
  tool call ends in `CANCELED`. A slow subscriber is dropped without
  stalling the run.
- **HTTP:** Hummingbird's test client checks auth (401), the version header,
  the SSE framing, and that ACP routes still work with A2A switched on.
- **End to end with 0001:** a Nawa client session calls this server over
  loopback with `task(agent:)`, and the client's `.subAgent` events and
  `"nawa/usage"` accounting match.
- **Interop**, by hand before marking this Implemented: call the server
  with the official A2A Python SDK client and its inspector tool.

## Plan

1. The `RouteProvider` hook in `ACPServer`, with no change in behaviour, and
   a test that ACP still works.
2. The `AgentA2AServer` skeleton: the card, auth and version check. Every
   method returns -32004.
3. The task store and `A2ATaskRun` with blocking `SendMessage`, `GetTask`
   and `CancelTask`.
4. Streaming: `SendStreamingMessage` and `SubscribeToTask` with several
   subscribers.
5. Multi-turn contexts, `ListTasks`, limits, and expiry.
6. `nawa serve --a2a` flags, `HarnessSessionFactory` adopting
   `A2ASessionFactory`, AGENTS.md updates, and the end-to-end test with
   0001.

## Open questions

1. **Approvals as `INPUT_REQUIRED`.** If Nawa gains tool approval prompts,
   the natural A2A mapping is `TASK_STATE_INPUT_REQUIRED`, with the caller
   answering through `taskId`. Do we design the task store for that now
   (tasks that pause and resume), or add it later?
2. **More than one agent per server.** Should one server publish several
   configured agents (different directories, prompts or tools), routed by
   the interface `tenant` field? It's useful for hosting, but it makes
   configuration bigger.
3. **A WebSocket binding.** The spec allows custom bindings, and ACP already
   runs over WebSocket here. Does a WebSocket A2A binding help anyone, or
   is SSE enough?
4. **Real streaming.** Is it worth sending `.stream` deltas as appended
   artifact chunks for the final answer, given that we only know a turn is
   final once it has ended without tool calls?
5. **Lasting tasks.** Do callers need `GetTask` to work after a restart?
   If so, the task snapshots and event logs need storage on disk.
