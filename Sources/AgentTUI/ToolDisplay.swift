import AgentCore

/// A tool call as one readable line: `shell  swift test`.
public struct ToolLabel: Sendable, Hashable {
    public var name: String
    /// The argument that says what the call does; may be empty. One line,
    /// not yet sanitized or cut to width (`Layout.row` does both).
    public var detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }

    public init(_ call: ToolCall) {
        let arguments = call.arguments.objectValue ?? [:]
        func string(_ key: String) -> String? { arguments[key]?.stringValue }

        switch call.name {
        case "shell": self.init(name: call.name, detail: Self.firstLine(string("command")))
        case "read_file", "edit_file": self.init(name: call.name, detail: string("path") ?? "")
        case "search": self.init(name: call.name, detail: string("pattern") ?? "")
        case "list_files":
            let parts = [string("path"), string("glob")].compactMap { $0 }
            self.init(name: call.name, detail: parts.joined(separator: " "))
        case "task": self.init(name: call.name, detail: Self.firstLine(string("prompt")))
        case "call_tool": self.init(name: call.name, detail: Self.serverTool(string("name") ?? ""))
        case "tool_search": self.init(name: call.name, detail: string("query") ?? "")
        case "remember": self.init(name: call.name, detail: Self.firstLine(string("note")))
        default:
            let detail = arguments.isEmpty ? "" : call.arguments.description
            self.init(name: Self.serverTool(call.name), detail: detail)
        }
    }

    /// `server__tool` (how MCP tools are often named) → `server · tool`.
    private static func serverTool(_ name: String) -> String {
        guard let range = name.range(of: "__"), range.lowerBound != name.startIndex,
              range.upperBound != name.endIndex else { return name }
        return name[..<range.lowerBound] + " · " + name[range.upperBound...]
    }

    private static func firstLine(_ text: String?) -> String {
        let lines = (text ?? "").split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? first + " …" : String(first)
    }
}

/// What a tool result comes to, in a few words: `exit 1 · 41 lines`.
///
/// Reads the shapes the built-in tools produce: the shell's leading
/// `exit code: N` line, and the marker `CapturedOutput` leaves when it
/// cut long output (`[… N lines omitted; full output at <path>]`), so
/// the count covers the whole output and the log path can be shown.
public struct ResultSummary: Sendable, Hashable {
    public var text: String
    public var isError: Bool
    /// Where the complete output was saved, when it was cut.
    public var fullOutputPath: String?

    public init(text: String, isError: Bool = false, fullOutputPath: String? = nil) {
        self.text = text
        self.isError = isError
        self.fullOutputPath = fullOutputPath
    }

    public init(_ result: ToolCallResult) {
        var lines = result.content.split(separator: "\n", omittingEmptySubsequences: false)
        var exitCode: Int?
        if let first = lines.first, let match = first.wholeMatch(of: /exit code: (-?\d+)/) {
            exitCode = Int(match.1)
            lines.removeFirst()
        }

        var omitted = 0
        var path: String?
        if let index = lines.firstIndex(where: { $0.wholeMatch(of: Self.omittedMarker) != nil }),
           let match = lines[index].wholeMatch(of: Self.omittedMarker) {
            omitted = Int(match.1) ?? 0
            path = String(match.2)
            lines.remove(at: index)
        } else if let index = lines.lastIndex(where: { $0.wholeMatch(of: Self.shortenedMarker) != nil }),
                  let match = lines[index].wholeMatch(of: Self.shortenedMarker) {
            path = String(match.1)
            lines.remove(at: index)
        }

        if lines.last?.isEmpty == true { lines.removeLast() }
        if lines == ["(no output)"] { lines = [] }

        if result.isError && exitCode == nil {
            let message = lines.first { !$0.allSatisfy(\.isWhitespace) } ?? "failed"
            self.init(text: String(message), isError: true, fullOutputPath: path)
            return
        }

        let count = lines.count + omitted
        var parts: [String] = []
        if let exitCode { parts.append("exit \(exitCode)") }
        parts.append(count == 0 ? "no output" : count == 1 ? "1 line" : "\(count) lines")
        if let path { parts.append("full output: \(path)") }
        self.init(text: parts.joined(separator: " · "), isError: result.isError, fullOutputPath: path)
    }

    nonisolated(unsafe) private static let omittedMarker = /\[… (\d+) lines omitted; full output at (.+)\]/
    nonisolated(unsafe) private static let shortenedMarker = /\[long lines shortened; full output at (.+)\]/
}
