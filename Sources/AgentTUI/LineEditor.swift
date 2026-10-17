/// The prompt being typed: text, cursor and history. Pure: it turns keys
/// into edits and leaves the screen to `Layout`.
///
/// The cursor counts `Character`s, so it never lands inside an emoji or
/// between a letter and its combining marks. The text can hold several
/// lines; Home/End, Ctrl-U/K and ↑/↓ work on the line the cursor is in.
public struct LineEditor: Sendable {
    /// What a key did.
    public enum Outcome: Sendable, Equatable {
        /// The text or cursor changed (or nothing needed to).
        case edited
        /// Enter: the text to send. The editor is already empty again.
        case submit(String)
        /// Not an editing key (Esc, Ctrl-C, Ctrl-D on an empty prompt,
        /// Ctrl-L…): the app decides.
        case unhandled
    }

    public private(set) var text: String = ""
    /// Position in `text`, counted in `Character`s.
    public private(set) var cursor: Int = 0
    /// Oldest first.
    public private(set) var history: [String]
    public let historyLimit: Int

    /// Index into `history` while browsing it; nil while editing the draft.
    private var historyIndex: Int?
    /// What was typed before ↑ started browsing history.
    private var draft = ""

    public init(history: [String] = [], historyLimit: Int = 1000) {
        self.historyLimit = historyLimit
        self.history = Array(history.suffix(historyLimit))
    }

    public var isEmpty: Bool { text.isEmpty }

    /// The cursor's line (0-based) and column in `Character`s within that line.
    public var cursorLocation: (line: Int, column: Int) {
        let before = text.prefix(cursor)
        let line = before.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let column = before.count - (before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0)
        return (line, column)
    }

    public mutating func apply(_ key: Key) -> Outcome {
        switch key {
        case .text(let string), .paste(let string): insert(string)
        case .newline: insert("\n")
        case .tab: insert("\t")
        case .enter: return submit()
        case .backspace, .control("h"): deleteBackward(1)
        case .delete: deleteForward(1)
        case .control("d"):
            guard !text.isEmpty else { return .unhandled }
            deleteForward(1)
        case .left, .control("b"): cursor = max(cursor - 1, 0)
        case .right, .control("f"): cursor = min(cursor + 1, text.count)
        case .home, .control("a"): cursor = lineStart(of: cursor)
        case .end, .control("e"): cursor = lineEnd(of: cursor)
        case .wordLeft: cursor = wordStart(before: cursor)
        case .wordRight: cursor = wordEnd(after: cursor)
        case .control("w"), .deleteWordBackward: deleteBackward(cursor - wordStart(before: cursor))
        case .control("u"): deleteBackward(cursor - lineStart(of: cursor))
        case .control("k"): deleteForward(lineEnd(of: cursor) - cursor)
        case .up: moveUp()
        case .down: moveDown()
        default: return .unhandled
        }
        return .edited
    }

    /// Empties the prompt (Esc, Ctrl-C) without touching history.
    public mutating func clear() {
        text = ""
        cursor = 0
        historyIndex = nil
    }

    /// Adds a sent prompt to history, skipping blanks and repeats of the last entry.
    public mutating func record(_ entry: String) {
        guard !entry.allSatisfy(\.isWhitespace), history.last != entry else { return }
        history.append(entry)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    // MARK: - Edits

    private mutating func submit() -> Outcome {
        let sent = text
        record(sent)
        clear()
        draft = ""
        return .submit(sent)
    }

    private mutating func insert(_ string: String) {
        let head = String(text.prefix(cursor)) + string
        text = head + text.dropFirst(cursor)
        // Inserting can merge Characters at the seam (a combining mark joins
        // the letter before it), so count the head again.
        cursor = min(head.count, text.count)
        historyIndex = nil
    }

    private mutating func deleteBackward(_ count: Int) {
        guard count > 0, cursor > 0 else { return }
        let count = min(count, cursor)
        text = String(text.prefix(cursor - count)) + text.dropFirst(cursor)
        cursor -= count
        historyIndex = nil
    }

    private mutating func deleteForward(_ count: Int) {
        guard count > 0, cursor < text.count else { return }
        text = String(text.prefix(cursor)) + text.dropFirst(cursor + count)
        historyIndex = nil
    }

    // MARK: - Lines and words

    private var characters: [Character] { Array(text) }

    private func lineStart(of position: Int) -> Int {
        let chars = characters
        var index = position
        while index > 0, chars[index - 1] != "\n" { index -= 1 }
        return index
    }

    private func lineEnd(of position: Int) -> Int {
        let chars = characters
        var index = position
        while index < chars.count, chars[index] != "\n" { index += 1 }
        return index
    }

    /// Start of the word before `position`: skip spaces, then non-spaces.
    private func wordStart(before position: Int) -> Int {
        let chars = characters
        var index = position
        while index > 0, chars[index - 1].isWhitespace { index -= 1 }
        while index > 0, !chars[index - 1].isWhitespace { index -= 1 }
        return index
    }

    private func wordEnd(after position: Int) -> Int {
        let chars = characters
        var index = position
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        while index < chars.count, !chars[index].isWhitespace { index += 1 }
        return index
    }

    // MARK: - Up and down

    /// In a multi-line prompt ↑ moves between lines; on the first line it
    /// recalls older history.
    private mutating func moveUp() {
        let start = lineStart(of: cursor)
        if start > 0 {
            let column = cursor - start
            let previousStart = lineStart(of: start - 1)
            cursor = min(previousStart + column, start - 1)
            return
        }
        guard !history.isEmpty else { return }
        let index: Int
        if let current = historyIndex {
            guard current > 0 else { return }
            index = current - 1
        } else {
            draft = text
            index = history.count - 1
        }
        show(history[index], at: index)
    }

    /// ↓ moves down a line; on the last line it walks history forward and
    /// finally back to the draft.
    private mutating func moveDown() {
        let end = lineEnd(of: cursor)
        if end < text.count {
            let column = cursor - lineStart(of: cursor)
            let nextStart = end + 1
            cursor = min(nextStart + column, lineEnd(of: nextStart))
            return
        }
        guard let current = historyIndex else { return }
        if current + 1 < history.count {
            show(history[current + 1], at: current + 1)
        } else {
            text = draft
            cursor = text.count
            historyIndex = nil
        }
    }

    private mutating func show(_ entry: String, at index: Int) {
        text = entry
        cursor = text.count
        historyIndex = index
    }
}
