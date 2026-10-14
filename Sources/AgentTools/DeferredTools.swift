import AgentCore
import Foundation

// Large tool sets (big MCP servers) offered through two small tools instead
// of one definition each. Every definition is sent with every request, so a
// server with fifty tools costs thousands of tokens per turn even when none
// of them is used.
//
// The set of tools sent to the model stays fixed: the model finds a tool with
// `tool_search` and runs it with `call_tool`. Adding definitions to the
// request as they are discovered would change the start of every request and
// break prompt caching each time.

/// Finds tools in a deferred set by keyword and returns their schemas.
public struct ToolSearchTool: Tool {
    public let tools: [any Tool]
    static let maxResults = 8

    public init(tools: [any Tool]) {
        self.tools = tools
    }

    public var definition: ToolDefinition {
        let names = tools.map(\.definition.name).sorted().joined(separator: ", ")
        return ToolDefinition(
            name: "tool_search",
            description: """
            Find more tools by keyword and get their input schemas; then run one with call_tool. \
            Available: \(names).
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Keywords or a tool name."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        guard let query = arguments.objectValue?["query"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'query'")
        }
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let scored = tools.map(\.definition).compactMap { definition -> (ToolDefinition, Int)? in
            let haystack = (definition.name + " " + definition.description).lowercased()
            let score = words.filter { haystack.contains($0) }.count
            return score > 0 ? (definition, score) : nil
        }
        let best = scored.sorted { $0.1 > $1.1 }.prefix(Self.maxResults).map(\.0)
        if best.isEmpty { return "No tools match \"\(query)\"." }

        return best.map { definition in
            "\(definition.name): \(definition.description)\ninput schema: \(definition.parameters.description)"
        }.joined(separator: "\n\n")
    }
}

/// Runs a tool from a deferred set by name.
public struct CallToolTool: Tool {
    public let tools: [any Tool]

    public init(tools: [any Tool]) {
        self.tools = tools
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "call_tool",
            description: "Run a tool found with tool_search, passing arguments that match its input schema.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("The tool's name.")]),
                    "arguments": .object(["type": .string("object"), "description": .string("The tool's input.")]),
                ]),
                "required": .array([.string("name")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        let fields = arguments.objectValue ?? [:]
        guard let name = fields["name"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'name'")
        }
        guard let tool = tools.first(where: { $0.definition.name == name }) else {
            throw ToolError.argumentError("no tool named \(name); use tool_search to find one")
        }
        return try await tool.run(arguments: fields["arguments"] ?? .object([:]))
    }
}
