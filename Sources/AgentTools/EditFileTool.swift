import AgentCore
import Foundation

/// Replaces an exact piece of text in a file, or creates a new file.
///
/// Output tokens cost several times more than input tokens, so having the
/// model rewrite a whole file to change one line is the most expensive thing
/// an agent does. With this tool the model writes only the lines that change.
public struct EditFileTool: Tool {
    public let workingDirectory: URL

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: """
            Replace old_string with new_string in a file. old_string must match the file exactly \
            (including indentation) and only once, unless replace_all is true; include enough \
            surrounding lines to make it unique. With an empty old_string, creates a new file \
            (or fills an empty one) containing new_string.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path, absolute or relative to the working directory."),
                    ]),
                    "old_string": .object([
                        "type": .string("string"),
                        "description": .string("The exact text to replace; empty to create a new file or fill an empty one."),
                    ]),
                    "new_string": .object([
                        "type": .string("string"),
                        "description": .string("The replacement text."),
                    ]),
                    "replace_all": .object([
                        "type": .string("boolean"),
                        "description": .string("Replace every occurrence instead of exactly one. Defaults to false."),
                    ]),
                ]),
                "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let fields = arguments.objectValue ?? [:]
        guard let path = fields["path"]?.stringValue,
              let oldString = fields["old_string"]?.stringValue,
              let newString = fields["new_string"]?.stringValue
        else {
            throw ToolError.argumentError("path, old_string and new_string are required strings")
        }
        let replaceAll = fields["replace_all"]?.boolValue ?? false
        let url = resolvedPath(path, in: workingDirectory)

        if oldString.isEmpty {
            return try createFile(at: url, path: path, contents: newString)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.runtimeError("\(path) does not exist; to create it, pass an empty old_string")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.runtimeError("cannot read \(path) as UTF-8 text")
        }
        // Literal: by default Foundation compares canonically, so a decomposed
        // "é" would match a precomposed one and the edit would touch text the
        // model never copied.
        let occurrences = Self.count(oldString, in: text)
        if occurrences == 0 {
            throw ToolError.runtimeError("old_string was not found in \(path); read the file and copy the text exactly")
        }
        if occurrences > 1 && !replaceAll {
            throw ToolError.runtimeError("old_string occurs \(occurrences) times in \(path); add surrounding lines to make it unique, or set replace_all")
        }

        let edited = text.replacingOccurrences(of: oldString, with: newString, options: .literal)
        try write(edited, to: url, path: path)
        return "Edited \(path) (\(occurrences) replacement\(occurrences == 1 ? "" : "s"))."
    }

    private static func count(_ needle: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: needle, options: .literal, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Creates the file, or fills one that exists but is empty (made by
    /// `touch` or an editor), which has no text to put in old_string.
    private func createFile(at url: URL, path: String, contents: String) throws -> String {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber
        let isEmptyFile = size?.intValue == 0
        if exists && !isEmptyFile {
            throw ToolError.runtimeError("\(path) already exists; pass the text to replace as old_string")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(contents, to: url, path: path)
        return exists ? "Wrote \(path), which was empty." : "Created \(path)."
    }

    /// Writes through a symlink to its target and keeps the file's
    /// permissions: the atomic write replaces whatever is at the path it is
    /// given, which would turn a link into a plain copy and drop modes such
    /// as the executable bit.
    private func write(_ text: String, to url: URL, path: String) throws {
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
        } catch {
            throw ToolError.runtimeError("cannot write \(path): \(error.localizedDescription)")
        }
    }
}
