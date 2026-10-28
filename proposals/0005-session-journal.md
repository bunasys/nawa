# 0005: Session journal: durable sessions for analysis and resume

- Status: Implemented (steps 1–5; step 6 is in the Hafez repo)
- Depends on: none

## Summary

Nawa keeps a session only in memory: when the process ends, the
conversation, the token counts and everything about how each model call
went are lost. This proposal adds a **session journal**: an append-only
JSON Lines file per session. It records every message once, every model
call (what was sent, which provider and model answered, tokens, cache
use, cost, timings, failovers, refusals), every tool run, and every time
the context is rewritten (cleared tool results, compaction). The journal
is written the same way in every mode (`repl`, `acp`, `serve`, and Nawa
linked as a library, as Hafez does in Sprites), because the `AgentLoop`
writes it, not a transport. The same file is what a session is restored
from: `nawa repl --resume`, ACP `session/load`, and unloading idle sessions
from a `serve` process all rebuild the loop by replaying it.

## Motivation

Two problems, one cause.

**No data to optimize with.** Token cost is Nawa's main running cost, and
the levers are known (AGENTS.md, "Token costs"): a stable prompt prefix,
when to clear tool results, when to compact, which model to use for
helpers. Today we tune them blind:
- `AgentEvent.assistant` carries usage per turn, but nothing keeps it.
  Hafez logs one line per run (`kind, turns, tokens`) and drops the rest
  after a successful review.
- Nobody can tell which tool results were resent on how many calls, when
  the prompt cache was busted and by what, how much compaction saved, or
  how long each provider took to answer.
- Compaction and `keepToolResults` destroy the original messages, so even
  a dump of the session at the end shows only what survived.

**Sessions don't survive the process.**
- `repl`: quitting loses the conversation; there is no resume.
- `acp` / `serve`: Nawa tells clients `loadSession: false`. A `serve`
  process keeps every session of a connection in memory until the
  connection closes (`ACPConnection.sessions`), idle or not, and a restart
  loses them all.
- Hafez: the Sprite's disk is restored from a checkpoint before every
  review, so anything left there is gone by the next one.

To be precise about "memory": while a run is going, the whole context has
to be in memory anyway, because every request resends it. What wastes
memory is everything else: sessions nobody is using, and nothing on disk
to rebuild them from. A durable record fixes both: idle sessions can be
dropped and rebuilt on demand, and the full history (including what
compaction removed) lives on disk instead of nowhere.

## Goals

- **One record, every mode.** The same file format from `repl`, `acp`,
  `serve`, Waku's one-shot prompts, and any program that links
  `AgentLoop` (Hafez). The loop writes it, so no mode can forget a field.
- **Enough to reconstruct every request.** For any model call, the exact
  list of messages and tools that was sent can be rebuilt from the
  journal, including after tool results were cleared or the context was
  compacted.
- **Everything an optimization needs**, per model call: provider and
  model asked for and answering, tokens split into fresh input, cache
  read, cache write and output, estimated cost, time to first token, total
  duration, failed attempts before it, stop reason, refusal. Per tool run:
  duration, output size, error.
- **Readable by common tools without Nawa.** JSON Lines, one record per
  line, snake_case fields, a version on every line. DuckDB, `jq`, pandas,
  SQLite's JSON functions and log shippers read it as is.
- **Restore from it.** A session can be rebuilt from its journal: repl
  `--resume`, ACP `session/load`, idle unloading in `serve`.
- **Never break a run.** A journal that can't be written costs the
  record, not the user's answer.

## Non-goals

- **Billing or audit.** The journal is written by the agent's own process,
  which also runs a shell for the model. A hijacked agent could edit it.
  Hafez's model proxy stays the source of truth for what was spent.
- **A query engine or dashboard in Nawa.** `nawa sessions show` prints a
  summary; real analysis happens in DuckDB or a notebook.
- **OpenTelemetry export in v1.** Field names are chosen so they map onto
  the OTel GenAI conventions (`gen_ai.usage.input_tokens`, …), and an
  exporter can come later. OTLP needs a collector, and span size limits
  don't fit full conversations.
- **Redacting secrets** from tool output. The journal holds what the model
  saw, secrets included (see Security).
- **Sharing a journal between processes.** One writer per file.

## Design

### Where it lives

```
AgentCore      JournalEntry (the record types), SessionJournal (protocol)
AgentJournal   JournalFile (writer), JournalReader (reader + replay)   ← new, Foundation only
AgentLoop      writes entries at the points where it knows the facts
AgentGateway   reports failed attempts on ModelResponse
AgentACP       session/load and idle unloading, built on JournalReader
nawa           opens a journal per session; `nawa sessions`; `repl --resume`
```

The protocol is one method:

```swift
public protocol SessionJournal: Sendable {
    func record(_ entry: JournalEntry)
}
```

`AgentLoop.init` gains `journal: (any SessionJournal)? = nil`. Nil, the
default, records nothing, so library users opt in. `AgentJournal` depends
on `AgentCore` and Foundation only: Hafez links Nawa into a static musl
binary, so no SQLite, no extra packages.

`record` writes the line right away, under a lock: one `write` costs
microseconds next to a model call that takes seconds, and writing at once
means the order in the file is the order things happened.

### Why JSON Lines, and not the alternatives

| Option | Why not |
| --- | --- |
| A `Session` JSON snapshot, rewritten each turn | Loses rewrites, timings and failed calls; rewriting the file each turn grows with the square of the session length. |
| SQLite | Great for queries, but a C dependency in every build (including static musl), schema migrations, and harder to ship from a Sprite or over a pipe. DuckDB and SQLite can load JSONL in one line when someone wants SQL. |
| OTLP / OpenTelemetry only | Needs a collector running next to every mode; built for spans and metrics, not for replaying a conversation. Kept as a later exporter. |

JSON Lines is append-only (a crash loses at most the last line), streams
over any pipe, and is readable by tools we don't write.

### The record format

Every line is one JSON object with the same envelope:

| Field | Meaning |
| --- | --- |
| `v` | Format version, `1`. New optional fields don't change it; removing or changing the meaning of a field does. |
| `type` | The record type (below). |
| `seq` | 1, 2, 3, … per file, so a reader can spot a missing line. |
| `at` | UTC time, ISO 8601 with milliseconds. |
| `session` | The session id. A sub-agent has its own id (see Sub-agents). |

Record types:

| `type` | Written when | Main fields |
| --- | --- | --- |
| `session_started` | A loop's first run begins | `nawa_version`, `mode` (`repl`, `acp`, `serve`, `waku`, `library`), `cwd`, `model`, `options` (max turns, budget, `keep_tool_results`, compaction thresholds, helper model, streaming, `pricing`), `parent` (sub-agents only) |
| `message` | A message is created | `message` (`id`, `role`, `content` as `{"type": "text" \| "tool_call" \| "tool_result" \| "opaque", …}` blocks), `appended_to_context`: true when it joined the end of the context; false for messages kept for reference only (a summarizer prompt and reply, a declined reply) and for messages a rewrite puts in place |
| `tools` | A tool set is first sent | `id` (a fresh UUID; recorded again only when the set changes), `definitions` |
| `run_started` | `run(prompt:)` begins | `prompt_message`, `model` |
| `model_call` | A model call ends, successfully or not | see below |
| `tool_run` | A tool returns | `call_id`, `name`, `started_at`, `duration_ms`, `output_chars`, `is_error` |
| `context_rewrite` | Messages in the context are replaced or removed | `reason` (`tool_results_cleared`, `compaction`, `declined_prompt_removed`), `removed` (message ids), `added` (message ids), `context` (the whole context after it, in order), `model_call` (the summary call, for compaction) |
| `steered` | A `steer` message joins the context | `message` |
| `note_saved` | The `remember` tool saved a note | `note` |
| `model_changed` | `AgentLoop.model` is set between turns | `from`, `to` |
| `refusal` | A model declined | the `RefusalNotice` fields |
| `run_finished` | A run ends | the `AgentResult` fields: `kind`, `num_turns`, `usage`, `cost_usd`, `stop_reason`, `error` |

A `model_call` holds what an optimization needs:

```json
{"v":1,"type":"model_call","seq":57,"at":"2026-10-28T08:01:12.481Z","session":"6f1c…",
 "id":"call-12","purpose":"turn",
 "request":{"messages":["m-001","m-002","…","m-041"],"tools":"5d0f…",
            "model":"claude-sonnet-5-5","provider":"anthropic","max_output_tokens":8192,
            "temperature":null,"streamed":true},
 "response":{"message":"m-042","stop_reason":"tool_use","model":"claude-sonnet-5-5",
             "provider":"anthropic","replaced_provider":null,"declined_by":[]},
 "usage":{"input_tokens":312,"cache_read_tokens":48210,"cache_write_tokens":1840,"output_tokens":406,
          "reasoning_tokens":288},
 "cost_usd":0.0231,
 "wire":{"request_bytes":214877,"provider_request_id":"req_011C…",
         "rate_limit":{"anthropic-ratelimit-requests-remaining":"3998"}},
 "timing":{"started_at":"2026-10-28T08:01:03.002Z","first_chunk_ms":2140,"duration_ms":9479},
 "failed_attempts":[{"provider":"runinfra","error":"HTTP 503 …","duration_ms":812}],
 "error":null}
```

`purpose` is `turn` or `compaction`. A call that threw
has `error` set and no `response`.

`wire` holds the few facts about the HTTP exchange that the messages
don't show, instead of the raw bodies (see "Why not raw HTTP capture"):
- `request_bytes`: the size of the body sent. Bytes per prompt token
  shows how much of the request is JSON overhead and tool schemas.
- `provider_request_id`: Anthropic's `request-id`, OpenAI's
  `x-request-id`. What a provider's support asks for about one call.
- `rate_limit`: the `anthropic-ratelimit-*` / `x-ratelimit-*` headers
  as the provider sent them (names lowercased), when sent. It shows how
  close a run came to throttling, which is what makes failovers. No other
  header is kept, so nothing that could carry a credential.

`usage.reasoning_tokens` is the part of output spent on reasoning, when
the provider reports it (OpenAI's `completion_tokens_details`). Clients
don't read these fields today; step 3 adds them. Fields a provider
doesn't send are left out, not zero.

### Rebuilding exactly what was sent

The request lists message ids instead of repeating their content, so a
200-call session doesn't store its conversation 200 times. That only
works if **an id always means the same content**. Today
`clearingOldToolResults` edits a message's content and keeps its id. The
loop changes that: a rewritten message gets a new id, and the rewrite is
recorded (`context_rewrite`: removed `m-007`, added `m-007b`). Nothing in
Nawa looks messages up by id across a rewrite (refusal handling uses
positions), so this is safe.

Replaying the context needs two rules only: a `message` with
`appended_to_context` joins the end; a `context_rewrite` replaces the
whole context with its `context` list (`JournalContents.context(ofSession:)`).

With that rule, a reader rebuilds any request by looking up its
`request.messages` ids and its `tools` id. A test proves it: a scripted
model saves every `ModelRequest` it receives, and the test checks that
the journal rebuilds each one exactly, across clearing and compaction.

The system prompt is the first `message` (role `system`), as it is in the
session today. A change to it shows up as a different first id, which is
how a reader spots a busted prompt cache.

### Why not raw HTTP capture

Storing every request and response body would add little for its cost:
- **The bodies are derived.** Each body is built by Nawa's wire client
  from the recorded messages and tools, and `session_started` records
  `nawa_version`, so the exact body can be rebuilt by running that
  version's encoder on the journal. Prompt-cache breakpoints are placed
  by the same code.
- **They grow with the square of the session.** Every request resends
  the whole conversation: 200 calls over a 100K-token context is roughly
  80 MB of bodies, for a session whose journal is a few MB. Each copy
  holds every secret the session saw, again.
- **What the bodies do hold that the journal doesn't** is a handful of
  fields: the request size, provider request ids, rate-limit headers,
  reasoning tokens. `wire` and `usage` record exactly those.
- **Hafez already has the bodies.** Its model proxy sees every request
  and reply; capture there, if ever needed, costs Nawa nothing.

Raw capture stays useful for one job: chasing a wire-format bug, such as
a client that serializes the same tools differently between calls and
silently busts the cache. For that, a short-lived opt-in debug switch
(`NAWA_SESSIONS_WIRE=1`, bodies to a separate file, headers stripped) is
enough, and can be added when such a bug shows up.

### Sub-agents

A `task` call starts a child loop. Its records go **into the parent's
file**, with the child's own `session` id and a `session_started` whose
`parent` is `{"session": "<parent id>", "call_id": "<task call id>"}`. One
top-level session is one file, and a reader can still split the child's
calls out.

### What it makes possible

These are the questions the format is built to answer, all from the file:
- **Cache efficiency per call**: `cache_read / (input + cache_read +
  cache_write)`. A drop marks a cache bust; the first message id that
  differs from the previous request says what caused it.
- **What each tool result really cost**: its size, times the number of
  later requests that included it, until it was cleared or compacted.
- **Approximate tokens per message**: the growth in prompt tokens between
  two consecutive calls, split over the messages added in between
  (providers report only totals).
- **Whether clearing and compaction pay off**: prompt size and cache hits
  before and after each `context_rewrite`, against the summary call's cost.
- **Provider behaviour**: time to first token and duration per provider
  and model, failover frequency, refusals by category.
- **Agent behaviour**: re-reads of the same file, tool error rates, turns
  per task, runs stopped by the loop detector or the budget.

Example, with DuckDB:

```sql
select session, count(*) calls,
       sum(usage.cache_read_tokens) / sum(usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens) cache_hit,
       sum(cost_usd) cost
from read_json('~/.local/state/nawa/sessions/*.jsonl', format='newline_delimited', union_by_name=true)
where type = 'model_call'
group by session order by cost desc;
```

### Writing it safely

- `JournalFile` appends one line per record with a single `write`, and
  `fsync`s after `run_finished` and on close. A crash loses at most what
  the OS hadn't flushed; the reader skips a cut-off last line.
- If a write fails, the journal reports it once through `JournalFile`'s
  `onFailure` and stops recording. The run goes on. The CLI prints it on
  stderr (never stdout: in `acp` mode that is the protocol).
- Files are created `0600` in a `0700` directory.

### Where each mode puts it

| Mode | Journal file | Restored by |
| --- | --- | --- |
| `repl` | state directory (below) | `nawa repl --resume [id]` (no id: the newest repl session in this directory) |
| `acp` (Zed, Waku) | state directory, named by the ACP session id | `session/load` |
| `serve` | state directory on the server host | `session/load`; idle unloading |
| Waku one-shot (`--prompt`) | state directory | not restored (one prompt) |
| Library (Hafez) | wherever the caller says: `JournalFile(path:)` | the caller's choice |

**State directory**: `$NAWA_SESSIONS_DIR`, else
`$XDG_STATE_HOME/nawa/sessions`, else `~/.local/state/nawa/sessions` (the
XDG place for history and logs, next to `~/.config/nawa` for the config).
Files are named `<started-at>-<session id>.jsonl`, e.g.
`2026-10-28T08-00-03Z-6f1c….jsonl`, so `ls` sorts them by age.
Recording is **on by default** in every CLI mode, like shell history;
`NAWA_SESSIONS=off` turns it off. In the library it stays opt-in: a
program passes a journal or records nothing.

**Retention**: nothing is deleted automatically. `nawa sessions prune
--older-than 30d` removes old files; automatic pruning can come later if
disk use turns out to need it.

**Hafez in Sprites.** The reviewer passes
`JournalFile(path: "/home/sprite/.hafez/session.jsonl")` to `AgentLoop`.
After the exec, hafez-server reads the file with the Sprites `fs/read` API,
exactly as it reads `verdict.json` today, and keeps it on its `/data`
volume next to `runs.jsonl` (keyed by run id). This has to happen before
the next review's checkpoint restore wipes the disk. Nothing is pushed out
of the Sprite live, so the egress policy doesn't change. The proxy's own
token counts stay the billing record; the journal adds what the proxy
can't see: tool timings, context rewrites, sub-agents, and which messages
each request carried.

### Restoring a session

`JournalReader.replay(_:)` rebuilds a session's state from its records:
the context messages in order (the two replay rules above), the model, the `remember` notes, total and helper
usage, and the last call's context size. A new
`AgentLoop(restoring: SessionState, …)` starts from it. Not restored: a
pending steer, a declined prompt waiting to be removed, gateway cooldowns.
Those belong to the run or the process.

The restored loop keeps appending to the same file.

- **repl** `--resume`: replays and prints the last few turns, then waits for the next prompt.
- **ACP `session/load`**: Nawa advertises `loadSession: true`. On
  `session/load` it replays the journal, sends the conversation back as
  `session/update` notifications (as the ACP spec requires), and answers.
- **Idle unloading in `serve`**: a session with no prompt running for
  `NAWA_SESSION_IDLE_MINUTES` (default 30) drops its `AgentLoop`, its
  MCP connections and its messages, and keeps only its id and file path.
  The next `session/prompt` or `session/load` rebuilds it. This is the
  memory saving: a `serve` process holds only the sessions in use.

### The `nawa sessions` command

- `nawa sessions list`: recent sessions for this directory (`--all` for every directory), with start time, turns, tokens and cost.
- `nawa sessions show <id>`: per-run and per-call summary: tokens, cache hit rate, cost, slowest calls, largest tool results.
- `nawa sessions path <id>`: the file, for `jq` or DuckDB.
- `nawa sessions prune --older-than <age>`: delete journals older than `<age>` (e.g. `30d`).

## Security

- **Journals hold everything the model saw**: file contents, command
  output, and any secrets in them. Mitigations: `0600` files in a `0700`
  directory; `NAWA_SESSIONS=off`; the docs say so plainly.
- **No credentials in the journal.** API keys, `Authorization`/`x-api-key`
  headers and identity tokens are never recorded. Providers appear by name
  and model only, not base URL plus key.
- **Path traversal through session ids.** `session/load` takes a
  client-chosen id. Ids are accepted only if they match the UUID format
  Nawa issues, and the file is looked up by listing the state directory,
  never by joining the id into a path.
- **The agent can read other journals.** The model runs a shell as the
  same user, so it can read `~/.local/state/nawa/sessions`, as it can read
  the rest of the home directory today. Not new, but worth stating; in
  Hafez each Sprite has only its own review's journal.
- **Tampering.** A prompt-injected agent can edit its own journal. Hence
  the non-goal: never bill or audit from it.

## Testing

- **Format**: golden JSONL files for each record type, decoded and
  re-encoded, so an accidental field rename fails a test.
- **Exact rebuild**: a scripted model saves every `ModelRequest`; after
  runs with tool calls, cleared tool results, a compaction, a refusal with
  fallback and a sub-agent, each request rebuilt from the journal must
  equal the one saved.
- **Replay**: a restored loop's messages, usage and notes equal the
  original loop's, and its next request is identical to the one the
  original would have sent.
- **Crash tolerance**: a file cut mid-line replays up to the last full
  record.
- **Failure isolation**: a journal whose writes fail leaves the run's
  events and result unchanged.
- **ACP**: `session/load` of a known id replays the conversation; an
  unknown or malformed id is refused; idle unloading then a prompt gives
  the same reply as without unloading.
- **Linux**: the suite runs in the `swift:6.4` container (AGENTS.md), since
  Hafez uses the static musl build.

## Plan

Each step leaves `swift build` and `swift test` green.

1. **Record types and stable ids** (`AgentCore`, `AgentLoop`):
   `JournalEntry`, `SessionJournal`; rewritten messages get new ids. No
   behaviour visible to users.
2. **`AgentJournal` module**: `JournalFile` (queued writer, `fsync`,
   permissions, failure handling) and `JournalReader` (decode, skip a
   cut-off line). Golden-file tests.
3. **The loop records**: `AgentLoop(journal:)` writes every record type;
   `Gateway` reports `failedAttempts` on `ModelResponse`; timings. The
   exact-rebuild test. The clients read reasoning tokens, provider request
   ids and rate-limit headers, and report the request size.
4. **CLI modes record**: `repl`, `acp`, `serve` and Waku one-shots open a
   journal per session in the state directory; `NAWA_SESSIONS`,
   `NAWA_SESSIONS_DIR`; `nawa sessions list|show|path|prune`. Release.
5. **Restore**: `JournalReader.replay`, `AgentLoop(restoring:)`,
   `repl --resume`, ACP `loadSession: true`, idle unloading in `serve`.
6. **Hafez** (in the Hafez repo): the reviewer passes a `JournalFile`; the
   server reads it back after each review and keeps it on `/data`; the
   control panel links to it.

## Decided

- **On by default** in the CLI modes; opt-in in the library.
- **Retention**: manual `nawa sessions prune --older-than 30d`; no
  automatic deletion for now.
- **No raw HTTP capture** for now: the few useful wire facts go into
  `wire` and `usage` instead (see "Why not raw HTTP capture"). A debug
  switch can be added for a specific wire-format bug.

## Open questions

1. **Sprite file size.** Journals with large tool outputs can reach tens
   of MB. Does Sprites' `fs/read` have a size limit like `fs/write`'s 16
   MiB? If so, the reviewer should gzip the file before exiting.
2. **Live forwarding over ACP.** A remote ACP client of `serve` may want
   the records as they happen (an `_nawa/journal` notification) or on
   request. Nothing needs it yet; leave it until a client does?
3. **Tool output size.** Should `tool_run` also say when output was cut to
   head and tail (`CapturedOutput`) and where the full text went? That
   needs tools to report it, which today they don't.
