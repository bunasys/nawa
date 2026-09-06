# AGENTS.md

This file follows the https://agents.md/ standard: it holds the instructions
for AI coding agents working in this repository. It is living documentation —
update it as the project evolves.

## Project overview

This SwiftPM package implements a **basic agent harness** (a "fundamental agent
runtime") in Swift. It embeds the agent loop described in the Claude Code Agent
SDK's agent-loop documentation, plus a configurable AI Gateway (OpenAI-compatible
chat completion API with multiple providers and auto model discovery), tool calls
and the MCP protocol, AGENTS.md loading per the agents.md standard, and the ACP
protocol (streamable HTTP + WebSocket transport) as the way agents communicate
with users/clients.

The package follows **CUPID** principles: Composable, Unix-philosophy (do one
thing well), Predictable, Idiomatic, Domain-Based, plus Locality of Behavior.

## Layout

- `Sources/AgentCore` — domain model: `Message`, `Role`, `ContentBlock`,
  `ToolCall`, `ToolCallResult`, `Session`, `Usage`, `AgentEvent`, `AgentResult`,
  `JSON` (a small dependency-free JSON value), `ToolRegistry`. No external deps.
- `Sources/AgentGateway` — `LanguageModel` protocol, `OpenAICompatibleClient`
  (chat/completions + SSE streaming + tool calling), `Gateway` with multiple
  providers and auto model discovery (`GET /v1/models`), `ProviderConfig`.
- `Sources/AgentJSONRPC` — JSON-RPC 2.0 envelope shared by MCP and ACP.
- `Sources/AgentTools` — built-in tools (`CurrentTimeTool`,
  `ShellTool`, `EchoTool`).
- `Sources/AgentInstructions` — `ProjectInstructions`: loads AGENTS.md from a
  directory, root-first / nearest-last so the closest file wins.
- `Sources/AgentLoop` — `AgentLoop`: the Runner/Event loop. Drives a session
  (init event → turns → tool execution → result), with maxTurns/maxBudget
  caps, usage accounting, and cost estimates.
- `Sources/AgentMCP` — `MCPClient`: spawns MCP servers, speaks JSON-RPC 2.0,
  exposes their tools.
- `Sources/AgentACP` — `ACPServer`: ACP over streamable HTTP and WebSocket on
  a single `/acp` endpoint (Hummingbird), plus the JSON-RPC frames.
- `Sources/agent` — executable: `serve` (ACP server) and `repl` (interactive).
- `Tests/` — 23 Swift Testing tests across 6 suites.

## Build & test

```
swift build
swift test
```

## Running

```
# start the ACP server (streamable HTTP + WebSocket on :7878/acp)
swift run agent serve

# interactive REPL against an OpenAI-compatible gateway
AGENT_GATEWAY_URL=https://api.openai.com/v1 \
AGENT_GATEWAY_API_KEY=$OPENAI_API_KEY \
AGENT_MODEL=gpt-4o-mini swift run agent repl
```

## Model/provider configuration

Providers are configured in code through `ProviderConfig` + `Gateway`:
multiple OpenAI-compatible endpoints (OpenAI, Azure, Ollama, vLLM, LiteLLM,
LM Studio…) can be registered; the gateway routes to the active one and can
auto-discover models via `GET /v1/models` when none is configured. API keys
may be literals or `env:NAME` references.

## Working with this repo (guidance for agents)

- Keep modules focused: each target in `Sources/` does one thing well.
- Domain types live in `AgentCore`; transports only ever speak `JSONRPCMessage`
  and domain types — never Thread/process primitives.
- Follow the Locality of Behavior principle: keep related code together, behaviors
  adjacent to the data they operate on.
- When adding a tool, add its test in the matching test suite.
- Commands: build with `swift build`, test with `swift test`. Both must stay
  green before pushing.
