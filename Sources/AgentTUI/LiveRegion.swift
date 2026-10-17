/// The redrawn part of the inline UI, below the transcript:
///
/// ```
///  ⠹ running shell · 4s · turn 2 · esc to interrupt
///   ⠹ shell  swift test
/// ```
///
/// or, while the reply streams in, its newest rows:
///
/// ```
///  ⠹ thinking · ~420 tokens · 6s · esc to interrupt
///    so the test fails because the fixture is built before the
///    temporary directory exists; moving it into the test body
/// ╭──────────────────────────────────────────╮
/// │ › also add a regression test_            │
/// ╰──────────────────────────────────────────╯
///  48.1k tokens (31k cached) · $0.031 · context 23%
/// ```
extension Layout {
    static let spinner: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Rows of the streamed reply shown under the status line.
    static let previewRows = 4

    /// The status line, a preview of what the model is streaming, and the
    /// calls still running, while a run is busy.
    public func status(_ live: LiveState, frame: Int, elapsedSeconds: Int, maxTurns: Int?) -> [StyledLine] {
        guard live.isBusy else { return [] }
        let spin = String(Self.spinner[frame % Self.spinner.count])
        let activity: String = switch live.phase {
        case .idle, .waiting: "waiting for the model"
        case .thinking: "thinking"
        case .writing: "writing"
        case .preparingTool: "preparing \(live.inFlight.preparing?.name ?? "a tool call")"
        case .runningTools where live.running.count == 1: "running \(live.running[0].label.name)"
        case .runningTools: "running \(live.running.count) tools"
        }
        var parts = [activity]
        if live.inFlight.characters > 0 {
            // About four characters per token: an estimate, until the usage arrives.
            parts.append("~\(Format.tokens(max(live.inFlight.characters / 4, 1))) tokens")
        }
        parts.append(Self.elapsed(elapsedSeconds))
        if let maxTurns { parts.append("turn \(live.turn)/\(maxTurns)") } else if live.turn > 1 { parts.append("turn \(live.turn)") }
        parts.append("esc to interrupt")
        var lines = [row(parts.joined(separator: " · "), style: .dim, prefix: StyledSpan(" \(spin) ", .color(.cyan)))]
        lines += preview(live)
        for tool in live.running {
            lines.append(callRow(tool.label, indent: 2, marker: StyledSpan("\(spin) ", .color(.cyan))))
            if let trace = tool.subAgent {
                lines += subAgentLines(trace, indent: 4, finished: false)
            }
        }
        return lines
    }

    /// The newest rows of the reasoning (dim) or reply being streamed.
    func preview(_ live: LiveState) -> [StyledLine] {
        let (text, style): (String, Style) = switch live.phase {
        case .thinking: (live.inFlight.thinking, .dim)
        case .writing: (live.inFlight.text, .plain)
        default: ("", .plain)
        }
        let shown = text.trimmingTrailingWhitespace
        guard !shown.isEmpty else { return [] }
        return Array(paragraph(shown, style: style, prefix: StyledSpan("   ")).suffix(Self.previewRows))
    }

    /// `4s`, `1m 05s`.
    static func elapsed(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        let rest = seconds % 60
        return "\(seconds / 60)m \(rest < 10 ? "0" : "")\(rest)s"
    }

    /// The bordered prompt and where the cursor goes in it (row 0 is the
    /// top border). Showing at most `maxRows` rows of text, scrolled so the
    /// cursor's row is visible.
    ///
    /// `text` is what the user typed or pasted, so it is wrapped by
    /// `Character` (the cursor counts those) and anything that could act
    /// on the terminal is shown as `�`. Tabs show as four spaces.
    public func promptBox(_ text: String, cursor: Int, maxRows: Int, placeholder: String? = nil) -> (lines: [StyledLine], cursor: InlineScreen.Cursor) {
        let inner = max(width - 4, 3)  // inside `│ ` and ` │`
        let rowWidth = max(inner - 2, 1)  // after `› ` or its indent
        var rows: [String] = [""]
        var used = 0
        var cursorAt = (row: 0, column: 0)

        func newRow() {
            rows.append("")
            used = 0
        }
        for (index, character) in text.enumerated() {
            if character == "\n" {
                if index == cursor { cursorAt = (rows.count - 1, used) }
                newRow()
                continue
            }
            let shown = Self.shown(character)
            let w = TextWidth.of(shown)
            if used + w > rowWidth && used > 0 { newRow() }
            if index == cursor { cursorAt = (rows.count - 1, used) }
            rows[rows.count - 1] += shown
            used += w
        }
        if cursor >= text.count {
            if used >= rowWidth { newRow() }
            cursorAt = (rows.count - 1, used)
        }

        // Keep the cursor's row in view.
        let visible = max(maxRows, 1)
        let first = min(max(cursorAt.row - visible + 1, 0), max(rows.count - visible, 0))
        let shownRows = rows[first..<min(first + visible, rows.count)]

        let border = StyledSpan("│ ", .dim)
        var lines = [StyledLine("╭" + String(repeating: "─", count: inner + 2) + "╮", .dim)]
        for (offset, row) in shownRows.enumerated() {
            let isFirst = first + offset == 0
            let lead = isFirst ? StyledSpan("› ", Style(bold: true, color: .cyan)) : StyledSpan("  ")
            var body = StyledSpan(row)
            if text.isEmpty, let placeholder { body = StyledSpan(TextWidth.truncate(placeholder, width: rowWidth), .dim) }
            let pad = StyledSpan(String(repeating: " ", count: max(rowWidth - TextWidth.of(body.text), 0)))
            lines.append(StyledLine([border, lead, body, pad, StyledSpan(" │", .dim)]))
        }
        lines.append(StyledLine("╰" + String(repeating: "─", count: inner + 2) + "╯", .dim))
        let position = InlineScreen.Cursor(row: cursorAt.row - first + 1, column: 4 + cursorAt.column)
        return (lines, position)
    }

    /// How a typed character is drawn: never as something the terminal acts on.
    private static func shown(_ character: Character) -> String {
        if character == "\t" { return "    " }
        guard let first = character.unicodeScalars.first else { return "" }
        if first.value < 0x20 || (0x7F...0x9F).contains(first.value) { return "�" }
        return String(character)
    }
}
