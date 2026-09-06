# BunaSys Agent — a small, CUPID-built agent harness in Swift

A basic functionality agent harness for the **BunaSys agent** project, built as
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
| `AgentGateway` | `LanguageModel` protocol, OpenAI-compatible client (streaming + tool calls), Gateway with multiple providers + auto model discovery | `AgentCore` |
| `AgentTools` | Built-in tools: `CurrentTimeTool`, `EchoTool`, `ShellTool` | `AgentCore` |
| `AgentInstructions` | `AGENTS.md` discovery/loading per agents.md | `AgentCore` |
| `AgentLoop` | The Runner/Event loop driving a session to completion | Core, Gateway, Tools, Instructions |
| `AgentMCP` | MCP client: spawn MCP servers, list + call their tools | Core, JSONRPC, Tools |
| `AgentACP` | ACP server over streamable HTTP + WebSocket (Hummingbird) | all of the above |
| `agent` | Executable: `serve` (ACP server) or `repl` | everything |

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

- ✅ **Configurable AI Gateway/API** — OpenAI chat-completions compatible,
  multiple providers (`ProviderConfig` + `Gateway`), SSE streaming, tool
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
swift test          # 23 tests, 6 suites — all green
swift run agent serve   # ACP over streamable HTTP + WebSocket on :7878/acp
swift run agent repl    # interactive loop
```
