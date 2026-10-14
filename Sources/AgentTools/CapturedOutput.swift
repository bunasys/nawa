import Foundation

/// Running a command and keeping its output small enough to send to a model.
///
/// Tool output is resent with every later turn, so one long build log can
/// cost more than the rest of the conversation. Long output is cut to its
/// first and last lines; the full text stays in a log file the agent can
/// search or read if it needs more.
enum CapturedOutput {
    static let headLines = 40
    /// Builds and tests print their verdict at the end, so the tail gets more room.
    static let tailLines = 80
    /// Minified files and generated code can put megabytes on one line.
    static let maxLineLength = 500

    struct Run {
        /// stdout and stderr interleaved, as a terminal would show them.
        var output: String
        var status: Int32
        /// Where the full output was written.
        var logFile: URL
    }

    /// Run `arguments` with `/usr/bin/env` (so `rg` resolves through PATH).
    ///
    /// Output goes to a file rather than a pipe: waiting for the process to
    /// exit before draining a pipe deadlocks once the output fills the pipe
    /// buffer (64 KB).
    static func run(_ arguments: [String], in directory: URL) throws -> Run {
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nawa-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logFile)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: logFile)) ?? Data()
        return Run(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus, logFile: logFile)
    }

    /// `run.output`, cut to its head and tail when long. The log file is
    /// deleted when nothing was cut and kept (and named) when something was.
    static func capped(_ run: Run) -> String {
        let capped = capped(run.output, fullOutputAt: run.logFile.path)
        if capped == run.output {
            try? FileManager.default.removeItem(at: run.logFile)
        }
        return capped
    }

    static func capped(_ text: String, fullOutputAt path: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shortened = lines.map { line in
            line.count > maxLineLength ? line.prefix(maxLineLength) + " […]" : line
        }
        let hasLongLines = shortened != lines
        let hasTooManyLines = lines.count > headLines + tailLines
        guard hasLongLines || hasTooManyLines else { return text }

        guard hasTooManyLines else {
            return shortened.joined(separator: "\n") + "\n[long lines shortened; full output at \(path)]"
        }
        let omitted = lines.count - headLines - tailLines
        let marker = "[… \(omitted) lines omitted; full output at \(path)]"
        return (shortened.prefix(headLines) + [Substring(marker)] + shortened.suffix(tailLines)).joined(separator: "\n")
    }
}

/// Resolves a tool's path argument: absolute paths as given, relative ones
/// against the session's working directory.
func resolvedPath(_ path: String, in root: URL) -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return root.appendingPathComponent(path)
}
