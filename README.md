# Nawa (نواة) — a small, CUPID-built agent harness in Swift

**Nawa** (نواة, "kernel") is the agent harness at the core of Buna Systems' agent work, built as
a SwiftPM package. It embeds the agent loop, a configurable multi-provider AI
gateway, tools + MCP, AGENTS.md loading, and the ACP protocol (streamable HTTP
+ WebSocket transport) as the way agents communicate with users and clients.

## Why we built it

This package is the study + implementation of two canonical agentic designs:

1. **Claude Code Agent SDK — the agent loop**
   (`code.claude.com/docs/en/agent-sdk/agent-loop`): a session receives a
   prompt, the model is asked to continue (each response may carry text and/or
   tool calls), requested tools run, results come back as tool messages, and the
   cycle repeats until the model produces a turn with no tool calls — at which
   point the loop yields a final result with usage/cost. Our `AgentLoop`
   implements exactly this cycle with `initEvent` → `assistant` →
   `toolResults` → `result` semantics, and honors `maxTurns` / `maxBudgetUSD`
   limits (result subtypes `success`, `errorMaxTurns`, `errorMaxBudgetUSD`,
   `errorDuringExecution`).

2. **Google ADK** — the Runner/Event loop: a Runner coordinates an Agent's
   execution, commits state changes to a `SessionService`, and yields `Event`s
   upstream. Our `AgentLoop` plays the Runner + LLM agent at once: it owns a
   `Session`, accumulates `Usage`, and streams `AgentEvent`s to whoever consumes
   them (hook: `onEvent`).

The package is designed to be a **composable foundation**: pick `Agent`, Tools,
`AgentGateway`, `AgentLoop`, or the bare `AgentCore` domain model and wire them
into bigger systems.

## Modules

| Module | What it does | Depends on |
| --- | --- | --- |
| `AgentCore` | Domain model — `Message`, `ContentBlock`, `ToolCall`, `Session`, `AgentEvent`, `JSON`, `ToolRegistry` | (none) |
| `AgentJSONRPC` | JSON-RPC 2.0 envelope shared by MCP and ACP | `AgentCore` |
| `AgentGateway` | `LanguageModel` protocol, OpenAI-compatible client (streaming + tool calls), Anthropic Messages client, Gateway with multiple providers + auto model discovery | `AgentCore` |
| `AgentTools` | Built-in tools: `CurrentTimeTool`, `EchoTool`, `ShellTool` | `AgentCore` |
| `AgentInstructions` | `AGENTS.md` discovery/loading per agents.md | `AgentCore` |
| `AgentLoop` | The Runner/Event loop driving a session to completion | Core, Gateway, Tools, Instructions |
| `AgentMCP` | MCP client: spawn MCP servers, list + call their tools | Core, JSONRPC, Tools |
| `AgentACP` | ACP server over streamable HTTP + WebSocket (Hummingbird), and ACP over stdio | all of the above |
| `nawa` | Executable: `serve` (ACP server), `acp` (ACP over stdio), `repl`, or `config` (per-directory provider setup) | everything |

## Design principles (CUPID)

- **Composable** — every module has a tiny, intention-revealing surface
  (`LanguageModel`, `Tool`, `ToolRegistry`, `ACPConnection`, `ACPEventStream`).
  Assembly happens in one place (`HarnessSessionFactory` in the executable).
- **Unix philosophy** — each component does one thing well and owns a single
  consistent model: `JSON` is the universal currency; `JSONRPCMessage` is the
  single wire format shared by MCP and ACP.
- **Predictable** — the loop yields typed `AgentEvent`s, limits are explicit,
  outbound streams buffer until a consumer attaches (POST/PUT→GET correlation),
  and there is no hidden global state.
- **Idiomatic** — Swift 6 concurrency (actors, async/await, `AsyncStream`),
  value types with `Sendable`, `Codable` everywhere, and the Hummingbird /
  Swift-server idiom for the HTTP + WebSocket transport.
- **Domain-Based** — the language is the domain's: `Session`, `Turn`,
  `ToolCall`, `Usage`, `ACPConnection`, `AgentResultKind` — no DAOs/managers.
- **Locality of behavior** — the code that changes together lives together:
  each tool carries its own schema and implementation; each transport carries
  its own send/receive paths.

## First-stage functionality

- ✅ **Configurable AI Gateway/API** — OpenAI chat-completions compatible
  and the Anthropic Messages API, multiple providers (`ProviderConfig` + `Gateway`), SSE streaming, tool
  calling, and auto **model discovery** via `GET /v1/models`.
- ✅ **Agent loop** — the full cycle with best-practice limits and result subtypes.
- ✅ **Tool calls & MCP protocol** — `ToolRegistry` + built-in tools + an MCP
  client (stdlib transport, JSON-RPC 2.0) surfacing remote tools.
- ✅ **AGENTS.md standard** — `ProjectInstructions` discovers and loads AGENTS.md.
- ✅ **Predictable** loop — the agent loop yields typed events and is testable
  with a scripted model.

## Build & run

```sh
swift build
swift test          # 50 tests — all green
swift run nawa config  # pick a provider + model for this directory (see below)
swift run nawa serve   # ACP over streamable HTTP + WebSocket on :7878/acp
swift run nawa acp     # ACP over stdio (for clients that launch the agent)
swift run nawa repl    # chat in the terminal (Esc interrupts; --plain for line mode)
```

## Configuring a provider per directory

`nawa config` walks you through adding a provider for the **current
directory**: it asks which API the provider speaks (`openai` or `anthropic`),
the base URL and API key, calls `GET /v1/models` on that endpoint, lets you pick a model from the list, and
saves the result to `~/.config/nawa/config.json` (or
`$XDG_CONFIG_HOME/nawa/config.json`, or `$NAWA_CONFIG_FILE`). The file is
written with `0600` permissions; type `env:NAME` as the key to store an
environment-variable reference instead of the secret itself.

A directory can hold several providers; the most recently added one is active.

```sh
nawa config              # add a provider (API → base URL → API key → choose model → name)
nawa config list         # show the providers configured for this directory
nawa config use <name>   # switch the active provider for this directory
nawa config remove <name>
```

`serve`, `acp` and `repl` resolve the gateway in this order: `NAWA_GATEWAY_URL`
env override → the saved config for the directory (for ACP, the session's
`cwd`) → `Gateways.json` (or `NAWA_GATEWAY_CONFIG`) → OpenAI with
`OPENAI_API_KEY`.

## Anthropic

Anthropic (and Anthropic-compatible gateways) use the Messages API rather
than chat completions. Choose `anthropic` in `nawa config`, or set it through
the environment:

```sh
NAWA_GATEWAY_API=anthropic \
NAWA_GATEWAY_URL=https://api.anthropic.com \
NAWA_GATEWAY_API_KEY=$ANTHROPIC_API_KEY \
NAWA_MODEL=claude-opus-5-5 swift run nawa repl
```

If your API key is not scoped to a single workspace, Anthropic requires the
workspace on every request: set `ANTHROPIC_WORKSPACE_ID=wrkspc_…` (or answer
the workspace question in `nawa config`, stored as `workspaceID`). Otherwise
requests fail with HTTP 400 "must include the anthropic-workspace-id header".

The base URL works with or without `/v1`. When `NAWA_GATEWAY_API_KEY` is unset,
the key falls back to `ANTHROPIC_API_KEY`. In a config file, add
`"api": "anthropic"` to the provider; providers without `api` stay OpenAI.
Claude's `thinking` blocks are sent back unchanged on the next request, so the
model keeps its reasoning across tool calls.

### Workload Identity Federation (OIDC)

Instead of an API key, Nawa can authenticate with a short-lived identity token
from an OIDC issuer you already trust (GitHub Actions, Kubernetes, AWS, Google
Cloud, Entra ID, Okta, SPIFFE, …). It exchanges the JWT at `/v1/oauth/token`
for an Anthropic access token, sends it as `Authorization: Bearer`, and
refreshes it before it expires. Set up the issuer, service account and
federation rule in the Claude Console (Settings → Workload identity), then
either export the variables the official SDKs read:

```sh
export ANTHROPIC_FEDERATION_RULE_ID=fdrl_...
export ANTHROPIC_ORGANIZATION_ID=00000000-0000-0000-0000-000000000000
export ANTHROPIC_SERVICE_ACCOUNT_ID=svac_...
export ANTHROPIC_IDENTITY_TOKEN_FILE=/var/run/secrets/anthropic.com/token  # or ANTHROPIC_IDENTITY_TOKEN
export ANTHROPIC_WORKSPACE_ID=wrkspc_...   # only if the rule spans several workspaces
```

or answer "yes" to the federation question in `nawa config` (asked for
Anthropic providers when you leave the API key empty). That stores the IDs and
the token file path in a `workloadIdentity` block; no secret is written to
disk. As in Anthropic's SDKs, an API key (`NAWA_GATEWAY_API_KEY`,
`ANTHROPIC_API_KEY`, or a stored key) takes precedence over federation, so
unset any API key you no longer want used.

The token file is read again on every exchange, so tokens your identity
provider rotates on disk are picked up. Identity tokens with a `jti` claim
can be exchanged only once, and every `nawa` process does its own exchange
(Waku, for example, starts one for the model list and one per agent). So the
file must hold a fresh token each time, which Kubernetes projected tokens
do. If a rejected exchange returns an opaque 401, the reason is in the Console under
Settings → Workload identity → History. Anthropic `ant` profile files
(`~/.config/anthropic`) are not read yet.

## Running inside Waku

[Waku](https://github.com/egoist/waku) has no slot for custom agents, but it
drives Kimi Code purely over ACP on stdio. Nawa implements the commands Waku
calls on that binary (`acp`, `--version`, `provider list [--json]`, and
`--prompt … --output-format text` for commit messages), so it can stand in
for Kimi Code:

1. `swift build -c release` and note the path to `.build/release/nawa`.
2. In Waku → Settings → Providers → Kimi Code, set the binary path to that file.
3. Configure the model: either run `nawa config` in each project directory, or
   export `NAWA_GATEWAY_*` variables in your shell profile. Waku launches
   agents with your login shell's environment.

Waku lists models from a temporary directory, not the project, so the model
picker is filled only when the `NAWA_GATEWAY_*` env vars are set. With
per-directory config alone the picker may be empty, and sessions use the
model configured for the project. Approvals: Nawa does not yet ask the client
for permission before running tools.

