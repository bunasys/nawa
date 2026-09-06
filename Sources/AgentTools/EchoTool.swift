import AgentCore
import Foundation

/// Echoes its input back.
///
/// Useful in tests and demos: it gives the loop a tool whose result is fully
/// deterministic, making the loop's behavior testable end-to-end.
public struct EchoTool: Tool {
    public init() {}
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "echo",
            description: "Echoes a string back to the caller unchanged.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The text to echo back."),
                    ]),
                ]),
                "required": .array([.string("text")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        guard let text = arguments.objectValue?["text"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'text'")
        }
        return text
    }
}
