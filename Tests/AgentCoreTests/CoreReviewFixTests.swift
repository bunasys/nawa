import AgentCore
import Foundation
import Testing

private struct NamedTool: Tool {
    let name: String
    let output: String
    var definition: ToolDefinition { ToolDefinition(name: name, description: output) }
    func run(arguments: JSON) async throws -> String { output }
}

struct ToolRegistryInitTests {
    @Test
    func duplicateNamesKeepTheLastToolInsteadOfCrashing() async throws {
        let registry = ToolRegistry([
            NamedTool(name: "b", output: "first"),
            NamedTool(name: "a", output: "only"),
            NamedTool(name: "b", output: "second"),
        ])
        #expect(registry.count == 2)
        #expect(registry.definitions.map(\.name) == ["a", "b"])
        #expect(try await registry["b"]?.run(arguments: .null) == "second")
    }
}

struct JSONNonFiniteTests {
    /// JSON has no NaN or infinity; the line must stay parseable.
    @Test
    func nonFiniteDoublesAreWrittenAsNull() throws {
        let value = JSON.array([.double(.nan), .double(.infinity), .double(-.infinity), .double(1.5)])
        #expect(value.description == "[null,null,null,1.5]")
        let reparsed = try JSONDecoder().decode(JSON.self, from: Data(value.description.utf8))
        #expect(reparsed == .array([.null, .null, .null, .double(1.5)]))
    }
}
