import AgentCore
import Foundation

/// Runs a shell command and captures its stdout/stderr.
///
/// The classic agent workhorse — lets the agent inspect, build, and test a
/// system the way a human shell user would.
public struct ShellTool: Tool {
    public init() {}
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "shell",
            description: """
            Run a shell command in the agent's working directory and return stdout and stderr. \
            Use for inspecting files, running builds/tests, and interacting with the environment.
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
        let workingDirectory = arguments.objectValue?["workingDirectory"]?.stringValue

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let status = process.terminationStatus

        var output = ""
        if !stdout.isEmpty { output += "stdout:\n\(stdout)" }
        if !stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + "stderr:\n\(stderr)" }
        if output.isEmpty { output = "(no output)" }
        output += "\nexit code: \(status)"

        if status != 0 {
            throw ToolError.runtimeError(output)
        }
        return output
    }
}
