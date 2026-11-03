/// One key press (or one paste) read from a terminal in raw mode.
///
/// Editing keys get their own cases. Control letters stay as `.control`
/// so the app decides what Ctrl-C, Ctrl-D and Ctrl-L mean.
public enum Key: Sendable, Hashable {
    /// Printable text typed at the keyboard; a fast typist or an
    /// unbracketed paste can put several characters in one value.
    case text(String)
    /// A bracketed paste, inserted as-is (newlines included, CR → LF).
    case paste(String)
    /// Plain Enter: send.
    case enter
    /// Enter with a modifier (Shift, Alt, Ctrl) or Ctrl-J: a newline in the prompt.
    case newline
    case tab
    case backspace
    case delete
    case left, right, up, down
    case home, end
    /// Alt-b / Ctrl-← and Alt-f / Ctrl-→.
    case wordLeft, wordRight
    /// Alt-Backspace.
    case deleteWordBackward
    case escape
    /// Ctrl plus a letter, lowercased: Ctrl-C is `.control("c")`.
    case control(Character)
}

/// Turns the bytes a terminal sends into `Key`s.
///
/// Pure and incremental: bytes may arrive in any split (a UTF-8 character
/// or an escape sequence cut across two reads), so anything incomplete is
/// kept for the next call. A lone Esc can't be told apart from the start
/// of a sequence until more bytes arrive or nothing does: call `flush()`
/// when `hasPending` stays true for a short while (~50 ms).
///
/// Unknown escape sequences are dropped, never inserted as text.
public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []
    /// Bytes of a bracketed paste still waiting for its end marker; nil
    /// outside a paste.
    private var paste: [UInt8]?
    /// `flush()` calls in a row, inside a paste, with no bytes in between.
    private var silentPasteFlushes = 0

    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)
    /// A paste whose end marker hasn't come after this many flushes (about
    /// two seconds at 50 ms each) is taken as it is. Without a limit a lost
    /// end marker would swallow every later key, Enter and Ctrl-C included.
    static let pasteGiveUpFlushes = 40

    public init() {}

    /// Whether bytes are held back waiting for the rest of a sequence or
    /// the end of a paste.
    public var hasPending: Bool { !pending.isEmpty || paste != nil }

    public mutating func decode(_ bytes: some Sequence<UInt8>) -> [Key] {
        pending.append(contentsOf: bytes)
        silentPasteFlushes = 0
        var keys: [Key] = []
        // One read can hold keys, a whole paste and more keys: go on while
        // the mode keeps switching.
        while !pending.isEmpty {
            let wasInPaste = paste != nil
            if wasInPaste {
                decodePaste(into: &keys)
            } else {
                decodeKeys(into: &keys)
            }
            let switchedMode = (paste != nil) != wasInPaste
            if !switchedMode { break }
        }
        return keys
    }

    /// Gives up waiting: a held-back lone Esc becomes `.escape`, and an
    /// incomplete UTF-8 or escape sequence is dropped. Inside a paste the
    /// held bytes are kept (the end marker may be split across reads)
    /// until the paste has been silent for `pasteGiveUpFlushes` calls.
    public mutating func flush() -> [Key] {
        if paste != nil { return flushPaste() }
        defer { pending.removeAll() }
        return pending.first == 0x1B ? [.escape] : []
    }

    /// Decodes keys from the start of `pending` until the bytes run out,
    /// a sequence is incomplete, or a bracketed paste starts.
    private mutating func decodeKeys(into keys: inout [Key]) {
        var index = 0
        while index < pending.count, paste == nil {
            guard let (key, next) = decodeOne(at: index) else { break }  // incomplete
            if let key { Self.append(key, to: &keys) }
            index = next
        }
        pending.removeFirst(index)
    }

    // MARK: - Decoding

    /// Decodes one key starting at `index`. Returns nil when more bytes are
    /// needed; a nil key with an index means bytes were consumed and dropped.
    private mutating func decodeOne(at index: Int) -> (Key?, Int)? {
        let byte = pending[index]
        switch byte {
        case 0x1B:
            return decodeEscape(at: index)
        case 0x0D: return decodeCarriageReturn(at: index)
        case 0x0A: return (.newline, index + 1)
        case 0x09: return (.tab, index + 1)
        case 0x7F, 0x08: return (.backspace, index + 1)
        case 0x01...0x1A: return (.control(Character(Unicode.Scalar(byte + 0x60))), index + 1)
        case 0x00, 0x1C...0x1F: return (nil, index + 1)
        case 0x20..<0x80: return (.text(String(Unicode.Scalar(byte))), index + 1)
        default: return decodeUTF8(at: index)
        }
    }

    /// A typed Enter arrives in a read of its own, or ends one. A CR with
    /// more bytes behind it in the same read is a line break pasted on a
    /// terminal without bracketed paste: a newline, so the paste isn't
    /// sent one line at a time.
    private func decodeCarriageReturn(at index: Int) -> (Key?, Int) {
        let next = index + 1
        guard next < pending.count else { return (.enter, next) }
        let isCRLF = pending[next] == 0x0A
        return (.newline, isCRLF ? next + 1 : next)
    }

    private func decodeUTF8(at index: Int) -> (Key?, Int)? {
        let lead = pending[index]
        let length: Int
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return (nil, index + 1)  // stray continuation or invalid byte
        }
        var end = index + 1
        while end < pending.count, end < index + length {
            guard pending[end] & 0xC0 == 0x80 else { return (nil, end) }  // broken sequence
            end += 1
        }
        guard end == index + length else { return nil }  // wait for the rest
        guard let string = String(validating: pending[index..<end], as: UTF8.self) else {
            return (nil, end)
        }
        // C1 controls (U+0080–U+009F) are escape-sequence introducers, not text.
        if let scalar = string.unicodeScalars.first, (0x80...0x9F).contains(scalar.value) {
            return (nil, end)
        }
        return (.text(string), end)
    }

    private mutating func decodeEscape(at index: Int) -> (Key?, Int)? {
        guard index + 1 < pending.count else { return nil }  // lone Esc, or more to come
        let next = pending[index + 1]
        switch next {
        case UInt8(ascii: "["):
            return decodeCSI(at: index + 2)
        case UInt8(ascii: "O"):
            guard index + 2 < pending.count else { return nil }
            let key: Key? = switch pending[index + 2] {
            case UInt8(ascii: "A"): .up
            case UInt8(ascii: "B"): .down
            case UInt8(ascii: "C"): .right
            case UInt8(ascii: "D"): .left
            case UInt8(ascii: "H"): .home
            case UInt8(ascii: "F"): .end
            case UInt8(ascii: "M"): .enter  // keypad Enter
            default: nil
            }
            return (key, index + 3)
        case 0x0D, 0x0A: return (.newline, index + 2)  // Alt-Enter
        case 0x7F, 0x08: return (.deleteWordBackward, index + 2)
        case 0x1B: return (.escape, index + 1)  // Esc Esc: the first one is a lone Esc
        case UInt8(ascii: "b"): return (.wordLeft, index + 2)
        case UInt8(ascii: "f"): return (.wordRight, index + 2)
        default:
            // Some other Alt-key: nothing uses it, so drop it whole.
            return (nil, index + 2)
        }
    }

    /// Parses `ESC [ params intermediates final` starting after the `[`.
    private mutating func decodeCSI(at start: Int) -> (Key?, Int)? {
        var end = start
        while end < pending.count {
            let byte = pending[end]
            if (0x40...0x7E).contains(byte) { break }
            guard (0x20...0x3F).contains(byte) else {
                return (nil, end)  // malformed: drop what we have, re-read this byte
            }
            end += 1
        }
        guard end < pending.count else { return nil }
        let final = pending[end]
        let params = String(decoding: pending[start..<end], as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        let next = end + 1
        let modifier = params.count > 1 ? (params[1] ?? 1) : 1

        switch final {
        case UInt8(ascii: "A"): return (.up, next)
        case UInt8(ascii: "B"): return (.down, next)
        case UInt8(ascii: "C"): return (Self.hasCtrlOrAlt(modifier) ? .wordRight : .right, next)
        case UInt8(ascii: "D"): return (Self.hasCtrlOrAlt(modifier) ? .wordLeft : .left, next)
        case UInt8(ascii: "H"): return (.home, next)
        case UInt8(ascii: "F"): return (.end, next)
        case UInt8(ascii: "u"):  // kitty keyboard protocol: CSI code ; mods u
            return (Self.modifiedKey(code: params.first ?? nil, modifier: modifier), next)
        case UInt8(ascii: "~"):
            switch params.first ?? nil {
            case 1, 7: return (.home, next)
            case 4, 8: return (.end, next)
            case 3: return (.delete, next)
            case 200:
                paste = []
                return (nil, next)
            case 27:  // xterm modifyOtherKeys: CSI 27 ; mods ; code ~
                let code = params.count > 2 ? params[2] : nil
                return (Self.modifiedKey(code: code, modifier: modifier), next)
            default: return (nil, next)
            }
        default:
            return (nil, next)
        }
    }

    /// A key reported with its modifiers (`modifier` is 1 + a bit mask:
    /// 1 Shift, 2 Alt, 4 Ctrl).
    private static func modifiedKey(code: Int?, modifier: Int) -> Key? {
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        let bits = max(modifier - 1, 0)
        let ctrl = bits & 4 != 0
        switch code {
        case 13: return bits == 0 ? .enter : .newline
        case 9: return .tab
        case 27: return .escape
        case 127, 8: return bits & 2 != 0 || ctrl ? .deleteWordBackward : .backspace
        default: break
        }
        if ctrl, scalar.properties.isAlphabetic, scalar.isASCII {
            return .control(Character(String(scalar).lowercased()))
        }
        if bits & ~1 == 0, code >= 0x20 {  // no modifier or Shift only: plain text
            return .text(String(scalar))
        }
        return nil
    }

    private static func hasCtrlOrAlt(_ modifier: Int) -> Bool {
        (max(modifier - 1, 0) & 6) != 0
    }

    // MARK: - Bracketed paste

    /// Moves `pending` into the paste and emits the paste once its end
    /// marker is there. A possible partial end marker stays in `pending`.
    private mutating func decodePaste(into keys: inout [Key]) {
        guard var collected = paste else { return }
        guard let markerStart = Self.firstIndex(of: Self.pasteEnd, in: pending) else {
            let keep = Self.partialSuffix(of: pending[...], matching: Self.pasteEnd)
            collected += pending.dropLast(keep)
            pending.removeFirst(pending.count - keep)
            paste = collected
            return
        }
        collected += pending[..<markerStart]
        pending.removeFirst(markerStart + Self.pasteEnd.count)
        paste = nil
        if let text = Self.pasteText(collected) { keys.append(.paste(text)) }
    }

    private mutating func flushPaste() -> [Key] {
        silentPasteFlushes += 1
        guard silentPasteFlushes >= Self.pasteGiveUpFlushes, let collected = paste else { return [] }
        let bytes = collected + pending
        pending.removeAll()
        paste = nil
        silentPasteFlushes = 0
        guard let text = Self.pasteText(bytes) else { return [] }
        return [.paste(text)]
    }

    /// Pasted bytes as text with line breaks as `\n`; nil when empty.
    private static func pasteText(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
        return text.isEmpty ? nil : text
    }

    private static func firstIndex(of marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) {
            if bytes[start..<(start + marker.count)].elementsEqual(marker) { return start }
        }
        return nil
    }

    /// How many trailing bytes of `bytes` could be the start of `marker`.
    private static func partialSuffix(of bytes: ArraySlice<UInt8>, matching marker: [UInt8]) -> Int {
        for length in stride(from: min(marker.count - 1, bytes.count), to: 0, by: -1) {
            if bytes.suffix(length).elementsEqual(marker.prefix(length)) { return length }
        }
        return 0
    }

    /// Typed characters that arrive together become one `.text`.
    private static func append(_ key: Key, to keys: inout [Key]) {
        if case .text(let more) = key, case .text(let text)? = keys.last {
            keys[keys.count - 1] = .text(text + more)
        } else {
            keys.append(key)
        }
    }
}
