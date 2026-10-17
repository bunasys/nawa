/// The escape sequences the UI emits: the portable VT100 / ECMA-48 subset
/// every terminal, tmux and mosh understand. No alternate screen, no
/// absolute positioning, no scroll regions, no queries.
enum Escape {
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let bracketedPasteOn = "\u{1B}[?2004h"
    static let bracketedPasteOff = "\u{1B}[?2004l"
    /// Erase from the cursor to the end of the screen.
    static let eraseBelow = "\u{1B}[J"
    static let reset = "\u{1B}[0m"

    static func up(_ rows: Int) -> String { rows > 0 ? "\u{1B}[\(rows)A" : "" }
    static func right(_ columns: Int) -> String { columns > 0 ? "\u{1B}[\(columns)C" : "" }

    /// SGR for `style`; empty for the plain style. With `color` off only
    /// bold and dim are kept (`NO_COLOR`).
    static func sgr(_ style: Style, color: Bool) -> String {
        var codes: [String] = []
        if style.bold { codes.append("1") }
        if style.dim { codes.append("2") }
        if color, let value = style.color {
            let index = Int(value.rawValue)
            codes.append(index < 8 ? "\(30 + index)" : "\(90 + index - 8)")
        }
        return codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
    }

    /// A laid-out line with its styles; ends with the attributes reset.
    static func render(_ line: StyledLine, color: Bool) -> String {
        var result = ""
        for span in line.spans where !span.text.isEmpty {
            let sgr = sgr(span.style, color: color)
            result += sgr.isEmpty ? span.text : sgr + span.text + reset
        }
        return result
    }
}

/// Draws the inline UI: committed lines go into the terminal's scrollback
/// once, and only the live region below them (status, prompt, footer) is
/// ever redrawn.
///
/// Every frame is one string, written with one `write(2)`: move up to the
/// top of the live region, erase to the end of the screen, print newly
/// committed lines (they scroll up into scrollback on their own), print
/// the live region, and put the cursor where the prompt's cursor is. Only
/// relative moves are used, so it doesn't matter where on the screen the
/// UI started.
public struct InlineScreen: Sendable {
    /// Where the terminal cursor is in the input, by live-region row and column.
    public struct Cursor: Sendable, Hashable {
        public var row: Int
        public var column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public var color: Bool
    /// Widths of the live region's rows as last drawn.
    private var drawnWidths: [Int] = []
    /// Where the cursor was left in the live region.
    private var drawnCursor = Cursor(row: 0, column: 0)

    public init(color: Bool) { self.color = color }

    /// One frame for a terminal `columns` wide. `committed` lines are
    /// printed above the live region and never drawn again. With a nil
    /// `cursor` the cursor is hidden.
    public mutating func frame(columns: Int, committed: [StyledLine], live: [StyledLine], cursor: Cursor?) -> String {
        var out = Escape.hideCursor + moveToTop(columns: columns) + "\r" + Escape.eraseBelow
        for line in committed {
            out += Escape.render(line, color: color) + "\r\n"
        }
        out += live.map { Escape.render($0, color: color) }.joined(separator: "\r\n")

        // The cursor is on the last live row, after its text.
        let lastRow = max(live.count - 1, 0)
        drawnWidths = live.map(\.width)
        if let cursor, !live.isEmpty {
            let row = min(max(cursor.row, 0), lastRow)
            out += Escape.up(lastRow - row) + "\r" + Escape.right(cursor.column) + Escape.showCursor
            drawnCursor = Cursor(row: row, column: cursor.column)
        } else {
            drawnCursor = Cursor(row: lastRow, column: live.last?.width ?? 0)
        }
        return out
    }

    /// Erases the live region and leaves the cursor at the start of the
    /// line where it began: for quitting, or before handing the terminal
    /// to another program.
    public mutating func clear(columns: Int, committed: [StyledLine] = []) -> String {
        frame(columns: columns, committed: committed, live: [], cursor: nil) + Escape.showCursor
    }

    /// Moves from the cursor's spot to the first row of the live region.
    ///
    /// When the terminal got narrower, terminals that reflow (most of them,
    /// and tmux) have re-wrapped the rows drawn at the old width, so the
    /// count goes by the current `columns`. Rows never filled the last
    /// column, so they only wrap when the window shrank.
    private func moveToTop(columns: Int) -> String {
        guard !drawnWidths.isEmpty else { return "" }
        let usable = max(columns, 1)
        func rows(_ width: Int) -> Int { max((width + usable - 1) / usable, 1) }
        var up = 0
        for width in drawnWidths.prefix(drawnCursor.row) { up += rows(width) }
        up += drawnCursor.column / usable
        return Escape.up(up)
    }
}
