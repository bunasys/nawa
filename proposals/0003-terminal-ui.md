# 0003: A terminal UI for `nawa repl`

- Status: Accepted
- Depends on: none

## Summary

Replace the `readLine()` loop in `AgentCLI.repl` with a small chat-style
terminal UI in a new `AgentTUI` target. It has a scrolling transcript, a
live status line, an editable multi-line prompt and a footer showing spend.
It works the same in a local terminal, over `ssh`/`mosh`, and inside
`tmux`/`screen`. The proposal looked at building it on
[SwiftTUI](https://github.com/rensbreur/SwiftTUI) and recommends **not**
doing that. Instead it proposes an *inline* renderer with no dependencies
(~800 lines), the same approach Claude Code and Codex CLI take. The section
"Why not SwiftTUI" explains the choice, and Option A describes what using
SwiftTUI would cost.

## Motivation

Today's REPL prints whatever happens and reads raw lines:

- No line editing beyond what the terminal's cooked mode gives. There is no
  history and no multi-line prompt, and pasting code with newlines sends
  each line as its own prompt.
- No way to interrupt a running turn. Ctrl-C kills the process and the
  conversation goes with it, even though `AgentLoop.run` already cancels
  cleanly when its stream ends (`onTermination → task.cancel()`).
- No feedback while the model thinks. The loop calls `gateway.complete`
  (not `stream`), so a turn can be silent for tens of seconds.
- Tool calls print raw JSON arguments. Results are cut at 200 characters
  with no pointer to the full output.
- Usage is printed after every turn, mixed in with the content.

The loop already produces everything a good UI needs: `AgentEvent` with
per-turn and per-session usage and cost, tool calls and results, and live
sub-agent events tagged with the parent `task` call id. What's missing is
the presentation layer.

## Goals

- **Works everywhere a shell works**: macOS Terminal, iTerm2, Ghostty,
  Linux consoles, `ssh`, `mosh`, `tmux`, `screen`. It uses only the most
  portable VT100/ECMA-48 subset (see "Terminal contract").
- **The transcript stays in the terminal's scrollback.** Native scroll,
  search, mouse selection and copy keep working, and the conversation is
  still on screen after you quit.
- A prompt editor with cursor movement, history, multi-line input and
  bracketed paste.
- **Interrupt, don't kill**: Esc / Ctrl-C cancels the current turn and
  keeps the session.
- Tool calls shown as one readable line each (`shell  swift test`), with a
  short result summary and the `CapturedOutput` log path when output was
  cut.
- Sub-agents shown nested under their `task` call.
- One footer line with session tokens, cost (when `NAWA_PRICE` is set), and
  context fill compared to the compaction threshold.
- A few slash commands: `/help`, `/clear`, `/cost`, `/tools`, `/exit`.
- Plain line mode (today's behaviour) when stdin/stdout is not a TTY,
  `TERM=dumb`, or `--plain`, so `echo "…" | nawa repl` keeps working.
- The state logic (key parsing, line editing, event → transcript, wrapping)
  is pure and unit-tested without a terminal.

## Non-goals (for now)

- A full-screen, windowed app: panes, file trees, diff viewers, mouse
  support.
- Token-by-token streaming. The loop doesn't emit `.stream` deltas today.
  The UI will be ready for them (see Decision 3), but changing the
  loop is a separate change.
- Tool permission prompts. The loop has no approval step yet. When one is
  added, the live region is where its prompt goes.
- Markdown rendering beyond the basics: code fences dimmed and indented,
  `**bold**`, and headings in bold. No syntax highlighting.
- Model or provider switching inside the UI. `nawa config use` already
  does this.
- Windows consoles.

## Research: what a terminal agent UI needs

Claude Code, Codex CLI, Aider, Gemini CLI and opencode have settled on a
common shape:

1. **Inline, not full-screen.** Claude Code, Codex CLI (by default) and
   Aider write finished output into normal scrollback and redraw only a
   small region at the bottom. Full-screen TUIs (opencode, and Codex's
   alt-screen mode) lose native scrollback and copy, behave worse in tmux
   and over high-latency ssh, and wipe the conversation on exit. For a
   tool whose output is mostly a transcript you read and copy from,
   inline is the better fit.
2. **Transcript blocks**: the user prompt, assistant text, then one compact
   line per tool call (`⏺ name  key-argument`) followed by an indented
   result summary (`└ 41 lines · exit 1`).
3. **A live status line**: a spinner, elapsed time, what is happening now
   ("thinking", "running shell"), and how to interrupt.
4. **A bordered input box** that grows with multi-line input.
5. **A quiet footer** with model, tokens, cost and context use.
6. **Esc interrupts.** Ctrl-C on an empty prompt asks you to press it again
   to quit. Ctrl-D on an empty prompt quits.

## Design

### What it looks like

```
 nawa · anthropic · claude-sonnet-4-5 · ~/BunaSystems/nawa · AGENTS.md

› fix the failing test in AgentToolsTests

● I'll run the tests first.
  ⏺ shell  swift test --filter AgentToolsTests
    └ exit 1 · 41 lines · full output: /tmp/nawa-7F1B3985.log
  ⏺ read_file  Sources/AgentTools/FileWalk.swift
    └ 120 lines
  ⏺ task  find where nested .gitignore files are parsed
    ↳ claude-haiku-4-5
      ⏺ search  gitignore
      ● FileWalk.ignoreRules only reads the root .gitignore.
    └ done · 3 turns · 8.2k tokens · $0.0040
● Fixed: FileWalk now merges nested .gitignore files (FileWalk.swift:88).
  The suite passes.
                                           ┄ scrollback above, live region below ┄
 ⠹ running shell · 4s · esc to interrupt
╭──────────────────────────────────────────────────────────────────────────╮
│ › also add a regression test for the nested case_                        │
╰──────────────────────────────────────────────────────────────────────────╯
 48.1k tokens (31k cached) · $0.031 · context 23% · /help
```

Everything above the live region is written to scrollback once and never
redrawn. The live region (status, input box, footer) is the only part
that gets redrawn.

### Keys

| Key | Idle | Turn running |
|---|---|---|
| Enter | send | queue as the next prompt |
| Shift-Enter, Alt-Enter, Ctrl-J | newline | newline |
| ← → Home End, Ctrl-A/E | move cursor | same |
| Ctrl-W / Ctrl-U / Ctrl-K | delete word / to start / to end | same |
| ↑ ↓ | history (in a multi-line buffer: move between lines) | same |
| Esc | clear input | **interrupt the turn** |
| Ctrl-C | clear input; on an empty prompt, press twice to quit | **interrupt the turn** |
| Ctrl-D | quit on an empty prompt | — |
| Ctrl-L | redraw the live region | same |
| paste | inserted as-is, newlines included (bracketed paste) | same |

Shift-Enter only works in some terminals. Many send the same `CR` as plain
Enter, and there is no way to tell them apart. Others report modified keys
and send a sequence of their own: xterm's *modifyOtherKeys*
(`ESC[27;2;13~`, sent by iTerm2, Ghostty, and tmux with `extended-keys`)
or the kitty keyboard protocol (`ESC[13;2u`). Today's `readLine()` REPL
puts that sequence into the prompt as text. This was seen in practice: a
prompt arrived as `error:[27;2;13~1. Inline.`. `KeyDecoder` turns Enter
with any modifier, in either encoding, into a newline. The UI does not
ask the terminal to turn these modes on (that is a terminal query/mode we
avoid). It just understands them when they arrive. Alt-Enter (`ESC CR`)
and Ctrl-J work in every terminal, so they stay the documented keys. Any
CSI sequence `KeyDecoder` doesn't know is dropped. It is never inserted
as text.

History lives in memory. It is saved to `$XDG_STATE_HOME/nawa/history`
only when `NAWA_HISTORY=1` is set (see Decisions).

### Module layout

```
Sources/AgentTUI                 // new. Depends on AgentCore only.
  Terminal.swift                 // the only file touching termios/ioctl/signals:
                                 //   raw mode, restore, size, SIGWINCH, write(Data)
  KeyDecoder.swift               // bytes → [Key]; ESC sequences, UTF-8 split
                                 //   across reads, bracketed paste. Pure.
  LineEditor.swift               // struct: buffer, cursor, history; apply(Key). Pure.
  Transcript.swift               // struct: reduce(AgentEvent) → committed [Block]
                                 //   + LiveState (running tools, sub-agents). Pure.
  Layout.swift                   // Block/LiveState → [StyledLine] for a width:
                                 //   word wrap, display width (wcwidth), styles. Pure.
  InlineScreen.swift             // writes committed lines to scrollback,
                                 //   redraws the live region with relative moves
  ChatApp.swift                  // the event loop: keys + agent events + ticks;
                                 //   slash commands; plain-mode fallback
```

`AgentTUI` does not import `AgentLoop`. The app gets what it needs as
values, so it can be tested with scripted event streams:

```swift
public struct ChatSession: Sendable {
    /// Starts one run; ending the stream early cancels it.
    public var send: @Sendable (String) -> AsyncThrowingStream<AgentEvent, any Error>
    /// Starts a fresh conversation (`/clear`).
    public var reset: @Sendable () -> Void
    /// Header facts: provider, model, cwd, whether AGENTS.md was loaded.
    public var header: SessionHeader
    /// Context-fill denominator (the compaction threshold), if any.
    public var contextLimit: Int?
}

public enum ChatApp {
    public static func run(_ session: ChatSession, mode: Mode = .auto) async throws
}
```

`Sources/nawa` builds the `ChatSession` from an `AgentLoop`: today's
`repl(gateway:options:)` body, minus the printing. `/clear` builds a new
`AgentLoop`. The loop yields its compaction note ("Compacted 40 older
messages into a summary.") on the stream as `.informational`. Its other
notes ("Hit maxTurns", "Loop error: …", the loop check) only go to
`onEvent`, because the `.result` that follows already says the same, and
the UI shows that.

### Event → transcript

`Transcript` is a reducer. Each `AgentEvent` either commits blocks (they
go to scrollback and are never touched again) or updates `LiveState`:

| Event | Effect |
|---|---|
| `.initEvent` | nothing (the header is printed at startup) |
| `.assistant(u)` | commit `● text` if non-empty; each tool call goes to LiveState as *running* with a one-line label; update the footer from `sessionUsage`/`sessionCost` and context from `usage.total` |
| `.subAgent(s)` | attach to the running `task` call with `s.callID`; show its latest step under it in the live region |
| `.toolResults(rs)` | for each result, commit the call line + `└ summary` (and the sub-agent's final line for `task`), then remove it from LiveState |
| `.informational(t)` | commit a dim `· t` line |
| `.result(r)` | on failure, commit `⚠ kind: message`; status → idle |
| `.stream(…)` | ignored for now; later it feeds an "in-flight text" block in LiveState |

Tool calls stay in the live region until their result arrives, so a
long-running `shell` shows a spinner on its own line. Committed lines are
final, which keeps scrollback append-only.

**Tool labels** come from a small table keyed by tool name, falling back
to `name  {compact JSON, cut to width}`. Examples: `shell` → `command`,
`read_file`/`edit_file` → `path`, `search` → `pattern`, `list_files` →
`path`/`glob`, `task` → the prompt's first line, `call_tool` → the
`name` argument, and `server__tool` → `server · tool`. **Result summaries**
show the line count, `exit N` when the shell output reports one, and the
`full output:` path when `CapturedOutput` cut the output (the UI finds the
`[… full output at <path>]` marker in the text, so no tool API change is
needed). Errors show in red with
their first line.

### Terminal contract (why it works over ssh)

The renderer uses only sequences that every VT100-descended terminal, tmux
and mosh support:

- `CR`, `LF`, `ESC[nA` (cursor up), `ESC[K` / `ESC[J` (erase to end of
  line / screen), `ESC[?25l` / `ESC[?25h` (hide/show cursor).
- SGR for bold, dim, and the 16 standard colours. No truecolour, no
  256-colour palette assumptions. `NO_COLOR` turns colour off.
- `ESC[?2004h` / `ESC[?2004l` for bracketed paste. Terminals that don't
  support it ignore it, and paste still works (newlines then send).

It does not use the alternate screen, absolute cursor positioning, scroll
regions, mouse reporting, or terminal queries (DA/DSR), whose replies get
lost or delayed over slow links.

**Redraw algorithm.** `InlineScreen` remembers how many rows the live
region took last time (`h`) and where the cursor sits inside it. Each frame
it builds one `String`: move up to the top of the region, `CR`, `ESC[J`,
any newly committed lines (these scroll into scrollback naturally), the new
live region, then a move to the cursor position in the input box. It
writes everything with a single `write(2)`, so ssh carries one packet
instead of hundreds of small writes. Frames are coalesced: a redraw happens
at most every 33 ms, and the spinner ticks at 8 Hz only while a turn is
running. Idle sessions send no bytes at all.

**Width.** `TIOCGWINSZ` gives the size at startup and on every `SIGWINCH`
(ssh forwards window changes). Wrapping uses display width, not
`Character` count: `wcwidth` from Darwin/Glibc per scalar, with combining
marks as 0 and East Asian wide characters and emoji as 2. This matters for
Arabic, CJK and emoji in prompts and replies. The renderer never writes in
the last column, to avoid the auto-wrap differences between terminals. On
resize, the live region is cleared and redrawn. Scrollback that was already
written reflows only if the terminal itself reflows it.

**Restoring the terminal.** Raw mode is entered with `cfmakeraw`-style
flags but keeps `OPOST`, so `\n` still maps to CRLF for any stray output.
The saved `termios` is restored on normal exit, on `SIGTERM` and `SIGHUP`
(an ssh disconnect), and through `atexit`, and the cursor is shown again
and bracketed paste turned off. `SIGINT` can't arrive in raw mode (Ctrl-C
is read as byte `0x03`), so interrupting a turn is ordinary key handling.
`SIGTSTP` (Ctrl-Z) restores cooked mode, suspends, and re-enters raw mode
with a full redraw on `SIGCONT`.

**Concurrency.** `ChatApp` is one `@MainActor` loop that merges three
`AsyncStream`s: keys (a detached reader of `stdin` → `KeyDecoder`),
agent events (the current run's stream), and ticks/resizes. Interrupting
means cancelling the task that drains the run's stream. Ending that
iteration triggers `AgentLoop`'s `onTermination`, which cancels the run.
The partial turn is then marked `⚠ interrupted` in the transcript.

### Plain mode

When `isatty(0) && isatty(1)` is false, `TERM` is `dumb` or unset, or
`--plain` is passed, `ChatApp` falls back to a line-mode printer driven by
the same `Transcript` reducer, writing committed blocks without colour or
cursor movement. This replaces today's `print` statements, so there is
only one formatting path.

### Why not SwiftTUI

SwiftTUI (rensbreur/SwiftTUI, checked at commit `5371330`, 2024-07-09) is a
nice SwiftUI-style toolkit. It builds with Swift 6.4 (in Swift 5 language
mode) on macOS and Linux. For this UI, though, reading the source turned
up blockers:

| Need | SwiftTUI today |
|---|---|
| Return to the CLI, clean up MCP children | `Application.start()` calls `dispatchMain()` and never returns; quitting calls `exit(0)` |
| Ctrl-C interrupts a turn | installs a `SIGINT` source that calls `stop()` → `exit(0)`; Ctrl-D (EOT) also exits |
| Multi-line prompt, paste | `TextField` is one line, append / delete-last only, and **submits on every `\n`**, so a pasted snippet becomes N prompts |
| Cursor keys, Home/End, Esc, history | the input parser only knows `ESC [ A–D`, which it uses to move focus; every other sequence goes into the focused field as text |
| Wrapped assistant text | `Text` is always one line; its width is its `Character` count, so wide or combining characters break the grid |
| Transcript that sticks to the bottom, PgUp | `ScrollView` only scrolls to keep the focused control visible |
| Scrollback, copy, keeping the conversation after exit | always runs in the alternate screen |
| Robust input | `availableData` → `String(data:encoding:)`; a UTF-8 character split across two reads is dropped |
| Maintenance | single maintainer, one tag (`0.1.0`), last commit July 2024 |

So using it would mean forking it and rewriting its run loop, input
handling, text field, text layout and scrolling: most of the library,
inside an unfamiliar codebase. And the result would still be a
full-screen app, which is the worse model for a transcript-heavy tool
(see Research, point 1).

**Option A (if we want SwiftTUI anyway).** Fork it to
`bunasys/SwiftTUI` and patch: a returning `start()`/`stop()`, a full key
decoder, a multi-line `TextEditor`, wrapping `Text` with `wcwidth`, a
bottom-anchored `ScrollView`, and no `SIGINT` handler. The transcript
model, labels and tests in this proposal stay the same, and only `Layout`
and `InlineScreen` get replaced by SwiftTUI views. Its view classes aren't
`Sendable`, so they need `@preconcurrency import` and main-actor hops from
the agent stream. Estimated at about twice the work of the inline
renderer, plus the ongoing upkeep of a fork.

## Security

- **Terminal escape injection.** Model text, tool output, file contents and
  MCP results can contain ESC sequences that would recolour the screen,
  move the cursor, set the window title, or use OSC 52 to write the
  clipboard. `Layout` strips C0/C1 control characters (except `\n` and
  `\t`, which expands to spaces) from all agent-supplied text before
  styling. Only the renderer emits escape sequences.
- **Paste.** Bracketed paste keeps pasted newlines from sending a prompt.
  Pasted text is never run as commands, only inserted into the buffer.
- **History file**, if enabled: mode `0600`. Prompts can contain secrets,
  so it is off by default and needs `NAWA_HISTORY=1` (Decision 2).
- **Log paths.** The UI only shows `CapturedOutput` paths. It never opens
  them.

## Testing

All in a new `AgentTUITests` suite (Swift Testing). None of it needs a TTY.

- `KeyDecoder`: arrows, Home/End variants (`ESC[H`, `ESC[1~`, `ESC OH`),
  Alt-Enter, Shift-Enter as `ESC[27;2;13~` and `ESC[13;2u`, unknown CSI
  sequences dropped, lone Esc, a UTF-8 character split across chunks, bracketed
  paste with embedded newlines and ESC bytes.
- `LineEditor`: insert/delete at the cursor, word deletion, multi-line
  up/down, history navigation that keeps the draft.
- `Transcript`: feed a scripted `[AgentEvent]` (two parallel tool calls, a
  `task` with sub-agent events, a failed result, an interruption) and
  check the committed blocks and live state.
- `Layout`: wrapping at width 20/80 with Arabic, CJK and emoji; never
  writing in the last column; control-character stripping; tool labels and
  result summaries, including the `full output:` path.
- `InlineScreen`: render into an in-memory sink and compare the exact byte
  string for a frame (relative moves only, one write per frame, no
  `ESC[?1049`).
- Manual checklist before marking it Implemented: Terminal.app, iTerm2,
  Ghostty, `ssh localhost`, `tmux` over ssh, `mosh`, a Linux VM console,
  and resizing during a turn.

## Plan

Each step leaves `swift build` and `swift test` green.

1. Add the `AgentTUI` target and tests with `KeyDecoder`, `LineEditor` and
   `Layout` (pure, nothing calls them yet).
2. Add `Transcript` and plain mode, and move `AgentCLI.repl` onto it.
   Output looks about the same as today, but there is now one formatting
   path, and `printSubAgent`/`usageLine` move into `AgentTUI`.
3. Add `Terminal` and `InlineScreen`, and have `ChatApp` run the inline UI
   when it is attached to a TTY. Add a `--plain` flag.
4. Interrupt, queued prompts, slash commands, and the footer's context
   fill.
5. Update AGENTS.md (layout + Running), README and the `nawa` usage text,
   and set this proposal's status.

## Decisions

Open questions settled when the proposal was accepted:

1. **Inline, not SwiftTUI.** The chat UI uses the dependency-free inline
   renderer. Option A stays on record in case full-screen views are ever
   wanted for other screens (for example, `nawa config` as a form). Those
   would not be on the chat path.
2. **History persistence is opt-in.** History is kept in memory by
   default. `NAWA_HISTORY=1` saves it to one file,
   `$XDG_STATE_HOME/nawa/history` (falling back to
   `~/.local/state/nawa/history`), with mode `0600`, capped at 1000
   entries. It is not split per directory: recalling a prompt from
   another project is useful, and one file is simpler to find and delete.
3. **Streaming is a separate change.** `LoopOptions.streamText` (the loop
   uses `gateway.stream` and yields `.stream(.textDelta)`) gets its own
   proposal. The `Transcript` reducer ignores `.stream` until then, and
   `LiveState` has room for an in-flight text block.
4. **`maxTurns` is shown, not asked about.** While a turn runs, the
   status line shows `turn 3/20`. When the cap is hit, the transcript
   commits `· stopped after 20 turns; send "continue" to keep going`.
   The session is kept, so the next prompt carries on from where it
   stopped. A modal "continue?" prompt would be the only modal in the
   UI, so it is left out.
