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
    /// A size cap next to the match cap (~3K tokens): 100 matches of long
    /// lines (JSON Lines, minified files) came to 20K characters in one
    /// session, and every later request resent them.
    static let maxOutputChars = 12_000
    /// How many of the files with matches past the cap are named.
    static let maxListedFiles = 10

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "search",
            description: """
            Search file contents with a regular expression (ripgrep syntax). Returns matching \
            lines as path:line:text, at most \(Self.defaultMaxMatches) by default and \
            \(Self.maxOutputChars / 1000)K characters; when cut, says which files had the rest and \
            the offset to see them. Skips files ignored by .gitignore.
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
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("Skip this many matches, to see the ones past a cut. Defaults to 0."),
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
        let offset = max(0, fields["offset"]?.intValue ?? 0)

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
        return Self.capped(lines, maxMatches: maxMatches, offset: offset)
    }

    /// The matches from `offset` on, up to `maxMatches` and `maxOutputChars`.
    /// When some are left out, a note says which, where they are, and the
    /// offset that shows the next ones, so the model can narrow the search
    /// or page on instead of guessing. Ripgrep's output is sorted, so the
    /// same search pages the same way every time.
    static func capped(_ lines: [String], maxMatches: Int, offset: Int = 0) -> String {
        guard offset < lines.count else {
            return "No matches past offset \(offset) (\(lines.count) in total)."
        }
        let remaining = lines.dropFirst(offset)
        var shown: [String] = []
        var shownChars = 0
        for line in remaining.prefix(maxMatches) {
            // Stop on whole lines; the first match always fits.
            let isOverCap = shownChars + line.count > maxOutputChars
            if isOverCap && !shown.isEmpty { break }
            shown.append(line)
            shownChars += line.count + 1
        }
        let first = offset + 1
        let last = offset + shown.count
        let isComplete = offset == 0 && last == lines.count
        if isComplete { return shown.joined(separator: "\n") }

        let stoppedBySize = shown.count < min(maxMatches, remaining.count)
        let reason = stoppedBySize ? " (stopped at \(maxOutputChars / 1000)K characters)" : ""
        var notice = "[showing matches \(first)-\(last) of \(lines.count)\(reason)"
        if last < lines.count {
            notice += "; pass offset=\(last) for the next ones, or narrow the pattern, path or glob"
            let files = filesWithMatches(lines.dropFirst(last))
            let listed = files.prefix(maxListedFiles).map { "\($0.path) (\($0.count))" }
            let unlisted = files.count - listed.count
            if !listed.isEmpty {
                notice += ". More matches in: " + listed.joined(separator: ", ") + (unlisted > 0 ? ", and \(unlisted) more files" : "")
            }
        }
        return shown.joined(separator: "\n") + "\n" + notice + "]"
    }

    /// Files and their match counts, most matches first (ties by path).
    /// A match line is `path:line:text`; the path ends at the first `:<digits>:`.
    private static func filesWithMatches(_ lines: ArraySlice<String>) -> [(path: String, count: Int)] {
        var counts: [String: Int] = [:]
        for line in lines {
            guard let lineNumber = line.range(of: ":[0-9]+:", options: .regularExpression) else { continue }
            counts[String(line[..<lineNumber.lowerBound]), default: 0] += 1
        }
        return counts.map { (path: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
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
            List files under a directory (recursively, sorted), skipping files ignored by \
            .gitignore. Filter with a glob such as "Sources/**/*.swift" to get every match (at most \
            \(Self.maxFiles)). Without a glob, a directory of more than \(Self.overviewThreshold) files \
            is shown as an overview: files two levels down and deeper folders with their file count.
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
        let wantsEveryFile = glob != nil || files.count <= Self.overviewThreshold
        if wantsEveryFile {
            return limited(files, to: Self.maxFiles, noun: "files", hint: "narrow the path or glob")
        }
        return Self.overview(of: files, under: path)
    }

    /// Past this many files, a listing without a glob is an overview.
    static let overviewThreshold = 200

    /// A big directory's shape rather than its every path: files up to two
    /// levels down, and each deeper folder once with its file count. A whole
    /// repository listed in full was 67K characters in one session, of which
    /// the model needed one folder name (proposal 0006).
    static func overview(of files: [String], under path: String) -> String {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var entries: [String] = []
        // Two levels when that stays short; one level for very wide trees.
        for depth in [2, 1] {
            var shownFiles: [String] = []
            var deeperFolders: [String: Int] = [:]
            for file in files {
                let relative = file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
                let parts = relative.split(separator: "/")
                if parts.count <= depth {
                    shownFiles.append(file)
                } else {
                    let folder = prefix + parts.prefix(depth).joined(separator: "/") + "/"
                    deeperFolders[folder, default: 0] += 1
                }
            }
            let folderEntries = deeperFolders.map { folder, count in
                "\(folder) (\(count) \(count == 1 ? "file" : "files"))"
            }
            entries = (shownFiles + folderEntries).sorted()
            if entries.count <= overviewThreshold { break }
        }
        let header = "\(files.count) files under \(path); deeper folders show their file count. "
            + "Pass a glob (e.g. \"**/*.py\") or a deeper path to list every file."
        return header + "\n" + limited(entries, to: maxFiles, noun: "entries", hint: "pass a deeper path")
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
