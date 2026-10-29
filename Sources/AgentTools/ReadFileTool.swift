import AgentCore
import Foundation

/// Reads a text file as numbered lines. The line numbers let the model point
/// at code precisely.
///
/// Whole files by default: paging through a file in windows costs a model
/// call per window, and agents then grep and read line ranges instead
/// (seen in Hafez's review logs), which costs more calls than the lines save.
/// The caps (2,000 lines, 40K characters) keep a big file from flooding the
/// context: one 83K-character read was resent on every later turn of a
/// session (proposal 0006).
public struct ReadFileTool: Tool {
    public let workingDirectory: URL
    static let defaultLimit = 2000
    /// A size cap next to the line cap (~10K tokens): 2,000 long lines can
    /// be 80K characters, and every later request resends them.
    static let maxChars = 40_000

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: """
            Read a text file as numbered lines: the whole file, up to \(Self.defaultLimit) lines or \
            \(Self.maxChars / 1000)K characters. For a large file, search it first and read the \
            part you need with offset and limit. Don't read a file you already have again unless \
            it changed. To read several files, call read_file for each in the same turn.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path, absolute or relative to the working directory."),
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("First line to read, starting at 1. Defaults to 1."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of lines to read. Defaults to \(Self.defaultLimit)."),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let fields = arguments.objectValue ?? [:]
        guard let path = fields["path"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'path'")
        }
        let offset = max(1, fields["offset"]?.intValue ?? 1)
        let limit = max(1, fields["limit"]?.intValue ?? Self.defaultLimit)

        let url = resolvedPath(path, in: workingDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError.runtimeError("cannot read \(path): \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.runtimeError("\(path) is not a UTF-8 text file")
        }
        if text.isEmpty { return "(empty file)" }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        guard offset <= lines.count else {
            throw ToolError.argumentError("offset \(offset) is past the end of \(path) (\(lines.count) lines)")
        }

        let lastAsked = min(lines.count, offset + limit - 1)
        var output: [String] = []
        var outputChars = 0
        var last = offset - 1
        for number in offset...lastAsked {
            var line = lines[number - 1]
            if line.count > CapturedOutput.maxLineLength {
                line = line.prefix(CapturedOutput.maxLineLength) + " […]"
            }
            let numbered = "\(number)\t\(line)"
            // Stop at whole lines once the size cap is reached; the first line always fits.
            let isOverCap = outputChars + numbered.count > Self.maxChars
            if isOverCap && !output.isEmpty { break }
            output.append(numbered)
            outputChars += numbered.count + 1
            last = number
        }
        if last < lines.count {
            let stoppedBySize = last < lastAsked
            let reason = stoppedBySize ? " (stopped at \(Self.maxChars / 1000)K characters)" : ""
            output.append("[showing lines \(offset)-\(last) of \(lines.count)\(reason); pass offset \(last + 1) to read on, or search for what you need]")
        }
        return output.joined(separator: "\n")
    }
}
