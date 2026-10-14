import AgentCore
import Foundation

/// Searches file contents with ripgrep (or `FileWalk` without it), returning
/// only matching lines.
///
/// A capped list of `path:line:text` matches tells the model where to look
/// without paying for whole files; it then reads just those lines.
public struct SearchTool: Tool {
    public let workingDirectory: URL
    static let defaultMaxMatches = 100

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "search",
            description: """
            Search file contents with a regular expression (ripgrep syntax). Returns matching \
            lines as path:line:text, at most \(Self.defaultMaxMatches) by default. Skips files \
            ignored by .gitignore.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Regular expression to search for."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File or directory to search. Defaults to the working directory."),
                    ]),
                    "glob": .object([
                        "type": .string("string"),
                        "description": .string("Only search files matching this glob, e.g. \"*.swift\"."),
                    ]),
                    "max_matches": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of matching lines to return. Defaults to \(Self.defaultMaxMatches)."),
                    ]),
                ]),
                "required": .array([.string("pattern")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let fields = arguments.objectValue ?? [:]
        guard let pattern = fields["pattern"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'pattern'")
        }
        let maxMatches = max(1, fields["max_matches"]?.intValue ?? Self.defaultMaxMatches)

        let path = fields["path"]?.stringValue ?? "."
        let glob = fields["glob"]?.stringValue

        // Sorted, so the same search gives the same output (and stays cacheable).
        var rgArguments = [
            "rg", "--line-number", "--with-filename", "--no-heading", "--color=never", "--sort=path",
            "--max-columns=\(CapturedOutput.maxLineLength)", "--max-columns-preview",
        ]
        if let glob { rgArguments += ["--glob", glob] }
        rgArguments += ["--regexp", pattern, path]

        let lines = try runRipgrep(rgArguments, in: workingDirectory)
            ?? FileWalk(workingDirectory: workingDirectory).search(pattern: pattern, under: path, glob: glob)
        if lines.isEmpty { return "No matches." }
        return limited(lines, to: maxMatches, noun: "matches", hint: "narrow the pattern, path or glob")
    }
}

/// Lists files with ripgrep (or `FileWalk` without it), skipping what
/// .gitignore ignores.
///
/// A capped, flat list instead of `find` or `ls -R`, which walk into build
/// directories and dependencies.
public struct ListFilesTool: Tool {
    public let workingDirectory: URL
    static let maxFiles = 500

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "list_files",
            description: """
            List files under a directory (recursively, sorted, at most \(Self.maxFiles)), skipping \
            files ignored by .gitignore. Filter with a glob such as "Sources/**/*.swift".
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "glob": .object([
                        "type": .string("string"),
                        "description": .string("Only list files matching this glob."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory to list. Defaults to the working directory."),
                    ]),
                ]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let fields = arguments.objectValue ?? [:]
        let path = fields["path"]?.stringValue ?? "."
        let glob = fields["glob"]?.stringValue

        var rgArguments = ["rg", "--files", "--sort=path"]
        if let glob { rgArguments += ["--glob", glob] }
        rgArguments.append(path)

        let files = try runRipgrep(rgArguments, in: workingDirectory)
            ?? FileWalk(workingDirectory: workingDirectory).files(under: path, glob: glob).map(\.display)
        if files.isEmpty { return "No files." }
        return limited(files, to: Self.maxFiles, noun: "files", hint: "narrow the path or glob")
    }
}

/// Runs ripgrep and returns its output lines, or nil when ripgrep is not
/// installed. Exit status 1 means "nothing found", which is an answer, not
/// an error.
private func runRipgrep(_ arguments: [String], in directory: URL) throws -> [String]? {
    let run = try CapturedOutput.run(arguments, in: directory)
    defer { try? FileManager.default.removeItem(at: run.logFile) }
    switch run.status {
    case 0:
        return run.output.split(separator: "\n").map(String.init)
    case 1:
        return []
    case 127:
        return nil
    default:
        throw ToolError.runtimeError("rg failed (exit code \(run.status)): \(run.output.prefix(1_000))")
    }
}

private func limited(_ lines: [String], to maxCount: Int, noun: String, hint: String) -> String {
    guard lines.count > maxCount else { return lines.joined(separator: "\n") }
    let shown = lines.prefix(maxCount).joined(separator: "\n")
    return shown + "\n[showing \(maxCount) of \(lines.count) \(noun); \(hint)]"
}
