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

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "shell",
            description: """
            Run a bash command in the agent's working directory and return its exit code and \
            combined stdout/stderr. Use for builds, tests, git and other commands. Long output \
            is cut to its first and last lines and saved in full to a file you can search. \
            Prefer read_file, search, list_files and edit_file for working with files.
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
                ]),
                "required": .array([.string("command")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        guard let command = arguments.objectValue?["command"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'command'")
        }
        var directory = workingDirectory
        if let requested = arguments.objectValue?["workingDirectory"]?.stringValue {
            directory = resolvedPath(requested, in: workingDirectory)
        }

        let run = try CapturedOutput.run(["bash", "-c", command], in: directory)
        let capped = CapturedOutput.capped(run)
        let output = capped.isEmpty ? "(no output)" : capped
        let result = "exit code: \(run.status)\n\(output)"
        if run.status != 0 {
            throw ToolError.runtimeError(result)
        }
        return result
    }
}
