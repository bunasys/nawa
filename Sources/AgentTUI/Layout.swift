/// The 16 standard terminal colours: the only ones every terminal, tmux
/// and mosh agree on.
public enum Color: UInt8, Sendable, Hashable {
    case black, red, green, yellow, blue, magenta, cyan, white
    case gray, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
}

public struct Style: Sendable, Hashable {
    public var bold: Bool
    public var dim: Bool
    public var color: Color?

    public init(bold: Bool = false, dim: Bool = false, color: Color? = nil) {
        self.bold = bold
        self.dim = dim
        self.color = color
    }

    public static let plain = Style()
    public static let bold = Style(bold: true)
    public static let dim = Style(dim: true)
    public static func color(_ color: Color) -> Style { Style(color: color) }
}

/// A run of text in one style. The text holds no control characters.
public struct StyledSpan: Sendable, Hashable {
    public var text: String
    public var style: Style

    public init(_ text: String, _ style: Style = .plain) {
        self.text = text
        self.style = style
    }
}

/// One screen row: never wider than the width it was laid out for.
public struct StyledLine: Sendable, Hashable, ExpressibleByStringLiteral {
    public var spans: [StyledSpan]

    public init(_ spans: [StyledSpan] = []) { self.spans = spans }
    public init(_ text: String, _ style: Style = .plain) { self.spans = [StyledSpan(text, style)] }
    public init(stringLiteral text: String) { self.init(text) }

    /// The text without styles.
    public var text: String { spans.map(\.text).joined() }
    /// Columns the line takes on screen.
    public var width: Int { spans.reduce(0) { $0 + TextWidth.of($1.text) } }
}

/// Lays text out in rows for a terminal `columns` wide.
///
/// The last column is never written: terminals disagree on where the
/// cursor goes after a character lands there (auto-wrap), and relative
/// redraws depend on knowing.
public struct Layout: Sendable {
    public var columns: Int

    public init(columns: Int) { self.columns = columns }

    /// Columns available to text.
    public var width: Int { max(columns - 1, 1) }

    /// Agent-supplied `text`, cleaned, wrapped and styled. The first row
    /// starts with `prefix`; later rows are indented to line up under the
    /// text (or by `indent` when given).
    public func paragraph(
        _ text: String,
        style: Style = .plain,
        prefix: StyledSpan? = nil,
        indent: Int? = nil
    ) -> [StyledLine] {
        let prefixWidth = prefix.map { TextWidth.of($0.text) } ?? 0
        let indent = min(indent ?? prefixWidth, width - 1)
        let firstWidth = max(width - prefixWidth, 1)
        let restWidth = max(width - indent, 1)
        let rows = TextWidth.wrap(Layout.sanitize(text), width: firstWidth, continuationWidth: restWidth)
        let pad = String(repeating: " ", count: indent)
        return rows.enumerated().map { index, row in
            var spans: [StyledSpan] = []
            if index == 0 {
                if let prefix { spans.append(prefix) }
            } else if indent > 0 {
                spans.append(StyledSpan(pad))
            }
            if !row.isEmpty { spans.append(StyledSpan(row, style)) }
            return StyledLine(spans)
        }
    }

    /// One row: `text` cleaned, joined onto one line and cut to fit with `…`.
    public func row(_ text: String, style: Style = .plain, prefix: StyledSpan? = nil) -> StyledLine {
        let prefixWidth = prefix.map { TextWidth.of($0.text) } ?? 0
        let flat = Layout.sanitize(text).split(whereSeparator: \.isNewline).joined(separator: " ")
        let cut = TextWidth.truncate(flat, width: max(width - prefixWidth, 1))
        return StyledLine((prefix.map { [$0] } ?? []) + [StyledSpan(cut, style)])
    }
}

extension Layout {
    /// Removes what could act on the terminal instead of being shown: C0
    /// controls (except newline and tab), DEL and C1 controls, which start
    /// escape sequences (colours, cursor moves, window titles, OSC 52
    /// clipboard writes). A lone CR becomes a newline and tabs become
    /// spaces up to the next multiple of four columns.
    ///
    /// Everything the agent supplies (model text, tool output, file
    /// contents, MCP results) goes through here: only the renderer emits
    /// escape sequences.
    public static func sanitize(_ text: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        var column = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar.value {
            case 0x0A:
                if !previousWasCR { result.unicodeScalars.append("\n") }
                column = 0
            case 0x0D:
                result.unicodeScalars.append("\n")
                column = 0
            case 0x09:
                let spaces = 4 - column % 4
                result += String(repeating: " ", count: spaces)
                column += spaces
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                result.unicodeScalars.append(scalar)
                column += 1  // close enough for tab stops; wide characters are rare before a tab
            }
        }
        return result
    }
}

/// How many columns text takes on a terminal.
///
/// Computed from Unicode properties rather than the C library's `wcwidth`,
/// which depends on the process locale and answers -1 for anything
/// non-ASCII under the "C" locale. Combining marks and format characters
/// take 0 columns, East Asian wide characters and emoji take 2. Arabic
/// letters take 1, their marks 0 (they belong to the letter's `Character`).
public enum TextWidth {
    public static func of(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $0 + of($1) }
    }

    public static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if first.value < 0x7F { return first.value >= 0x20 ? 1 : 0 }
        // Emoji: shown wide by default, or asked to be with VS16 (U+FE0F).
        if first.properties.isEmojiPresentation || scalars.contains("\u{FE0F}") { return 2 }
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control, .lineSeparator, .paragraphSeparator:
            return 0
        default:
            break
        }
        return isWide(first.value) ? 2 : 1
    }

    /// East Asian Wide and Fullwidth ranges (Unicode 15, UAX #11), minus the
    /// emoji already caught by `isEmojiPresentation`.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF,
             0x1B000...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// Cuts `text` to `width` columns, ending in `…` when something was cut.
    public static func truncate(_ text: String, width: Int) -> String {
        guard of(text) > width else { return text }
        guard width > 1 else { return width == 1 ? "…" : "" }
        var result = ""
        var used = 0
        for character in text {
            let w = of(character)
            if used + w > width - 1 { break }
            result.append(character)
            used += w
        }
        return result + "…"
    }

    /// Word-wraps `text` (already sanitized) into rows of at most `width`
    /// columns; rows after the first may get a different `continuationWidth`.
    ///
    /// Breaks at spaces; a word longer than a row is split, never inside a
    /// `Character`. Newlines are kept as row breaks and leading indentation
    /// is kept, but the spaces at a wrap point are dropped.
    public static func wrap(_ text: String, width: Int, continuationWidth: Int? = nil) -> [String] {
        var rows: [String] = []
        func limit() -> Int { max(rows.isEmpty ? width : (continuationWidth ?? width), 1) }

        for hardLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var row = ""
            var used = 0
            var wrapped = false  // whether this hard line has already wrapped once

            func breakRow() {
                while row.last == " " { row.removeLast(); used -= 1 }
                rows.append(row)
                row = ""
                used = 0
                wrapped = true
            }

            for token in tokens(hardLine) {
                let tokenWidth = of(token)
                if token.first == " " {
                    if wrapped && row.isEmpty { continue }  // no leading spaces after a wrap
                    if used + tokenWidth <= limit() {
                        row += token
                        used += tokenWidth
                    } else {
                        breakRow()
                    }
                    continue
                }
                if used + tokenWidth <= limit() {
                    row += token
                    used += tokenWidth
                } else if tokenWidth <= limit() && used > 0 {
                    breakRow()
                    row = String(token)
                    used = tokenWidth
                } else {
                    for character in token {
                        let w = of(character)
                        if used + w > limit() && used > 0 { breakRow() }
                        row.append(character)
                        used += w
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Alternating runs of spaces and non-spaces.
    private static func tokens(_ line: Substring) -> [Substring] {
        var result: [Substring] = []
        var start = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if next == line.endIndex || (line[next] == " ") != (line[index] == " ") {
                result.append(line[start..<next])
                start = next
            }
            index = next
        }
        return result
    }
}
