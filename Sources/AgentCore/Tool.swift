import Foundation

/// Static description of a tool's callable surface, sent to the model.
public struct ToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    /// JSON Schema for the input parameters.
    public var parameters: JSON

    public init(name: String, description: String, parameters: JSON = .object(["type": .string("object"), "properties": .object([:])])) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Errors a tool can throw while running.
public enum ToolError: Error, Sendable {
    case argumentError(String)
    case runtimeError(String)
}

/// A capability an agent can invoke.
///
/// Meeting CUPID's "Unix philosophy / single-purpose" guidance: a `Tool` is the
/// atomic unit of agent behavior. Each tool knows its own name, description,
/// input schema, and how to run. The implementation that executes it lives with
/// its definition (locality of behavior).
public protocol Tool: Sendable {
    /// Returns the statically declared definition of this tool.
    var definition: ToolDefinition { get }

    /// Runs the tool with parsed arguments, returning text output.
    /// - Throws: `ToolError` for argument/runtime failures.
    func run(arguments: JSON) async throws -> String
}

extension Tool {
    /// Wraps a run into a `ToolCallResult` correlated with the originating call.
    public func result(for call: ToolCall) async -> ToolCallResult {
        do {
            let output = try await run(arguments: call.arguments)
            return ToolCallResult(callID: call.id, name: call.name, content: output)
        } catch {
            return ToolCallResult(callID: call.id, name: call.name, content: String(describing: error), isError: true)
        }
    }
}

/// A set of tools callable by the model, keyed by name.
public struct ToolRegistry: Sendable {
    private var tools: [String: any Tool]
    public init(_ tools: [any Tool] = []) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.name, $0) })
    }

    public subscript(name: String) -> (any Tool)? { tools[name] }

    public func tool(named name: String) -> (any Tool)? { tools[name] }

    public var definitions: [ToolDefinition] {
        tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    public var count: Int { tools.count }

    public mutating func register(_ tool: any Tool) {
        tools[tool.definition.name] = tool
    }

    public mutating func register(contentsOf tools: [any Tool]) {
        for tool in tools { register(tool) }
    }

    /// Merge another registry into this one.
    public mutating func merge(_ other: ToolRegistry) {
        tools.merge(other.tools) { _, new in new }
    }
}
