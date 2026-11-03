import Foundation

/// Splits text into lines at `\n`, dropping a `\r` before it.
///
/// Swift's `split(separator: "\n")` compares Characters, and `"\r\n"` is a
/// single Character, so CRLF text never splits. Splitting on unicode scalars
/// handles both line endings. Like `split(omittingEmptySubsequences: false)`,
/// text ending in a newline gives an empty last line.
func splitLines(_ text: String) -> [Substring] {
    text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { scalars in
        let line = Substring(scalars)
        return line.unicodeScalars.last == "\r" ? line.dropLast() : line
    }
}
