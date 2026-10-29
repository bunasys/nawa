import AgentCore

/// Facts shown once at startup:
/// ` nawa · anthropic · claude-sonnet-4-5 · ~/src/nawa · AGENTS.md · 12 skills`.
public struct SessionHeader: Sendable, Hashable {
    public var provider: String?
    public var model: String?
    public var directory: String
    /// The name of the nearest instructions file loaded (`AGENTS.md` or
    /// `CLAUDE.md`), if any.
    public var instructionsFile: String?
    /// How many skills the session can use.
    public var skillCount: Int

    public init(
        provider: String? = nil,
        model: String? = nil,
        directory: String,
        instructionsFile: String? = nil,
        skillCount: Int = 0
    ) {
        self.provider = provider
        self.model = model
        self.directory = directory
        self.instructionsFile = instructionsFile
        self.skillCount = skillCount
    }
}

/// How transcript pieces look on screen: committed blocks, the header and
/// the footer. Both the inline UI and plain mode use these rows.
extension Layout {
    /// Sub-agent steps kept in a committed `task` block; older ones are
    /// counted, not shown.
    static let maxSubAgentSteps = 8

    public func lines(for block: Block) -> [StyledLine] {
        switch block {
        case .prompt(let text):
            return [StyledLine()] + paragraph(text, style: .bold, prefix: StyledSpan("› ", Style(bold: true, color: .cyan)))
        case .assistant(let text):
            return paragraph(text, prefix: StyledSpan("● ", .bold))
        case .tool(let tool):
            return lines(for: tool)
        case .note(let text):
            return paragraph(text, style: .dim, prefix: StyledSpan("· ", .dim))
        case .warning(let text):
            return paragraph(text, style: .color(.yellow), prefix: StyledSpan("⚠ ", .color(.yellow)))
        }
    }

    func lines(for tool: ToolBlock) -> [StyledLine] {
        var lines = [callRow(tool.label, indent: 2)]
        if let trace = tool.subAgent {
            lines += subAgentLines(trace, indent: 4, finished: true)
        }
        let (text, style): (String, Style) = switch tool.summary {
        case nil: ("interrupted", .color(.yellow))
        case let summary? where summary.isError: (summary.text, .color(.red))
        case let summary?: (tool.subAgent?.outcome ?? summary.text, .dim)
        }
        lines.append(row(text, style: style, prefix: StyledSpan("    └ ", .dim)))
        return lines
    }

    /// `⏺ shell  swift test`, cut to one row.
    public func callRow(_ label: ToolLabel, indent: Int, marker: StyledSpan = StyledSpan("⏺ ", .color(.green))) -> StyledLine {
        let pad = StyledSpan(String(repeating: " ", count: indent))
        let name = StyledSpan(Layout.sanitize(label.name), .bold)
        let used = indent + TextWidth.of(marker.text) + TextWidth.of(name.text)
        guard !label.detail.isEmpty, used + 3 <= width else {
            return StyledLine([pad, marker, StyledSpan(TextWidth.truncate(name.text, width: max(width - indent - 2, 1)), .bold)])
        }
        let detail = row(label.detail, style: .dim, prefix: StyledSpan(String(repeating: " ", count: used + 2)))
        return StyledLine([pad, marker, name, StyledSpan("  ")] + detail.spans.dropFirst())
    }

    /// The sub-agent's model and steps, under its `task` call. While it
    /// runs only the latest step is shown; once committed, the last few.
    public func subAgentLines(_ trace: SubAgentTrace, indent: Int, finished: Bool) -> [StyledLine] {
        let pad = String(repeating: " ", count: indent)
        var lines = [row(trace.model ?? "sub-agent", style: .dim, prefix: StyledSpan(pad + "↳ ", .dim))]
        let keep = finished ? Self.maxSubAgentSteps : 1
        let hidden = trace.steps.count - keep
        if hidden > 0 && finished {
            lines.append(row("⋯ \(hidden) earlier step\(hidden == 1 ? "" : "s")", style: .dim, prefix: StyledSpan(pad + "  ")))
        }
        for step in trace.steps.suffix(keep) {
            switch step {
            case .tool(let label):
                lines.append(callRow(label, indent: indent + 2))
            case .text(let text):
                lines.append(row(text, prefix: StyledSpan(pad + "  ● ")))
            }
        }
        return lines
    }

    public func header(_ header: SessionHeader) -> StyledLine {
        var parts = ["nawa"]
        if let provider = header.provider { parts.append(provider) }
        if let model = header.model { parts.append(model) }
        parts.append(header.directory)
        if let file = header.instructionsFile { parts.append(file) }
        if header.skillCount > 0 { parts.append(header.skillCount == 1 ? "1 skill" : "\(header.skillCount) skills") }
        return row(parts.joined(separator: " · "), style: .dim, prefix: StyledSpan(" "))
    }

    /// ` 48.1k tokens used (31k cached) · $0.031 · context 27.6k/120k (23%)`,
    /// plus `extra`
    /// (for example a `/help` hint).
    public func footer(_ stats: SessionStats, contextLimit: Int?, extra: String? = nil) -> StyledLine {
        var parts: [String] = []
        // Everything sent and received so far, summed over all model calls.
        // Each call resends the conversation, so this grows much faster than
        // the context and can pass the model's window; it is spend, not size.
        var tokens = "\(Format.tokens(stats.usage.total)) tokens used"
        if stats.usage.cacheReadTokens > 0 { tokens += " (\(Format.tokens(stats.usage.cacheReadTokens)) cached)" }
        parts.append(tokens)
        if let cost = stats.cost { parts.append(Format.cost(cost)) }
        // The conversation's size at the last call against the point where
        // older messages get summarized (not the model's window).
        if let contextLimit, contextLimit > 0 {
            let percent = min(stats.contextTokens * 100 / contextLimit, 999)
            parts.append("context \(Format.tokens(stats.contextTokens))/\(Format.tokens(contextLimit)) (\(percent)%)")
        }
        if let extra { parts.append(extra) }
        return row(parts.joined(separator: " · "), style: .dim, prefix: StyledSpan(" "))
    }
}
