import AgentCore
import Foundation

/// Reads part of a text file as numbered lines.
///
/// Reading a window instead of the whole file (`cat`) keeps tool output, and
/// so every later request, small. The line numbers let the model point at
/// code precisely.
public struct ReadFileTool: Tool {
    public let workingDirectory: URL
    static let defaultLimit = 400

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: """
            Read a text file as numbered lines, \(Self.defaultLimit) lines at a time by default. \
            Use offset and limit to read a specific part; use search to find the lines you need first.
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

        let last = min(lines.count, offset + limit - 1)
        var output: [String] = []
        for number in offset...last {
            var line = lines[number - 1]
            if line.count > CapturedOutput.maxLineLength {
                line = line.prefix(CapturedOutput.maxLineLength) + " […]"
            }
            output.append("\(number)\t\(line)")
        }
        if last < lines.count {
            output.append("[showing lines \(offset)-\(last) of \(lines.count); pass offset \(last + 1) to read on]")
        }
        return output.joined(separator: "\n")
    }
}
