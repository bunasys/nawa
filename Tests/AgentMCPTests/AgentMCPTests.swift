import AgentMCP
import Foundation
import Testing

struct AgentMCPTests {
    @Test
    func mcpServerConfigCodable() throws {
        let config = MCPServerConfig(name: "fs", command: "/usr/bin/npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], env: ["FOO": "bar"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test
    func mcpToolDefinitionAsToolDefinition() {
        let tool = MCPToolDefinition(name: "read_file", description: "reads a file", inputSchema: .object(["type": .string("object")]))
        let def = tool.asToolDefinition
        #expect(def.name == "read_file")
        #expect(def.description == "reads a file")
    }
}
