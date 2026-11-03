import AgentCore
import Foundation

/// Runs a shell command and captures its output.
///
/// The classic agent workhorse — lets the agent inspect, build, and test a
/// system the way a human shell user would. Long output is cut to its first
/// and last lines (see `CapturedOutput`), with the full text left in a file.
public struct ShellTool: Tool {
    /// Where commands run unless the call names another directory.
    public let workingDirectory: URL
    /// The shell commands run in: the first `bash` on `PATH`, else `/bin/sh`.
    public let shell: URL

    /// - Parameter shell: Nil picks one with `findShell`.
    public init(
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        shell: URL? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.shell = shell ?? Self.findShell()
    }

    /// The fallback where there is no bash (minimal containers, Alpine):
    /// every POSIX system has `/bin/sh`.
    static let posixShell = URL(fileURLWithPath: "/bin/sh")

    /// The first executable `bash` in `searchPath` (a `PATH`-style list),
    /// else `/bin/sh`. Picked once, so the tool description can name the
    /// shell the model is writing for.
    static func findShell(searchPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL {
        findExecutable(named: "bash", searchPath: searchPath) ?? posixShell
    }

    /// A command that runs this long is stopped, with its children.
    static let defaultTimeoutSeconds = 600

    private var isBash: Bool { shell.lastPathComponent == "bash" }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "shell",
            description: shellDescription + """
             in the agent's working directory and return its exit code and \
            combined stdout/stderr. Use for builds, tests, git and other commands. Long output \
            is cut to its first and last lines and saved in full to a file you can search. \
            A command still running after timeout_seconds (default \(Self.defaultTimeoutSeconds)) is \
            stopped together with the processes it started. Prefer read_file, search, list_files \
            and edit_file for working with files.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to run."),
                    ]),
                    "workingDirectory": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to run the command in. Defaults to the agent's working directory."),
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("Stop the command after this many seconds. Defaults to \(Self.defaultTimeoutSeconds)."),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ])
        )
    }

    /// The start of the description. Under `sh`, the model is told to keep
    /// to POSIX syntax, since it writes bash by habit.
    private var shellDescription: String {
        if isBash { return "Run a bash command" }
        return "Run a POSIX sh command (bash is not installed: no [[ ]], arrays, <(…) or other bash-only syntax)"
    }

    public func run(arguments: JSON) async throws -> String {
        guard let command = arguments.objectValue?["command"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'command'")
        }
        var directory = workingDirectory
        if let requested = arguments.objectValue?["workingDirectory"]?.stringValue {
            directory = resolvedPath(requested, in: workingDirectory)
        }

        let timeoutSeconds = max(1, arguments.objectValue?["timeout_seconds"]?.intValue ?? Self.defaultTimeoutSeconds)

        let run = try await CapturedOutput.run(shell, ["-c", command], in: directory, timeout: .seconds(timeoutSeconds))
        let capped = CapturedOutput.capped(run)
        let output = capped.isEmpty ? "(no output)" : capped
        let result: String
        switch run.ending {
        case .exited(let code):
            result = "exit code: \(code)\n\(output)"
        case .killedBySignal(let signal):
            result = "killed by signal \(signal)\n\(output)"
        case .timedOut(let seconds):
            result = "timed out after \(seconds) seconds; the command and the processes it started were stopped\n\(output)"
        }
        if run.exitCode != 0 {
            throw ToolError.runtimeError(result)
        }
        return result
    }
}
