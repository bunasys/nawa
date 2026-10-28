# Proposals

Design proposals for larger changes to Nawa: new protocols, new modules,
changes that cross several targets. Small fixes don't need one.

A proposal says what we would build and why, and settles the hard questions
before any code is written. It is not a promise to build it.

## Format

One markdown file per proposal, named `NNNN-short-title.md`, numbered in
the order they are written. Each one starts with a header:

```
- Status: Draft | Accepted | Implemented | Rejected | Superseded by NNNN
- Depends on: NNNN (if any)
```

and then covers, in this order:

1. **Summary**: one paragraph.
2. **Motivation**: the problem, and why now.
3. **Goals / Non-goals**: what is in and out of scope.
4. **Design**: modules, types, wire format, behaviour, errors.
5. **Security**: what can go wrong, and how we stop it.
6. **Testing**: how we prove it works.
7. **Plan**: steps that each leave `swift build` and `swift test` green.
8. **Open questions**: what still needs deciding.

Designs should fit the rules in [AGENTS.md](../AGENTS.md): one job per
module, domain types in `AgentCore`, transports that only speak
`JSONRPCMessage` and domain types.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-a2a-client.md) | A2A client: remote agents as sub-agents | Draft |
| [0002](0002-a2a-server.md) | A2A server: Nawa as a remote agent | Draft |
| [0003](0003-terminal-ui.md) | A terminal UI for `nawa repl` | Implemented |
| [0004](0004-streaming-progress.md) | Show progress while the model thinks | Implemented |
| [0005](0005-session-journal.md) | Session journal: durable sessions for analysis and resume | Draft |
