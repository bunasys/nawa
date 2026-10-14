import AgentCore
import Foundation

/// A tool that reads the current date and time.
///
/// Useful as a smoke-test tool: it needs no arguments and returns immediately,
/// giving the loop something cheap to call while verifying the plumbing.
public struct CurrentTimeTool: Tool {
    public init() {}
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "current_time",
            description: "Returns the current wall-clock date and time (UTC).",
            parameters: .object(["type": .string("object"), "properties": .object([:])])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
