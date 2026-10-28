import AgentCore
import Foundation
import Testing

struct AgentCoreTests {
    @Test
    func jsonRoundTrips() throws {
        let value: JSON = .object([
            "name": .string("echo"),
            "args": .array([.int(1), .double(2.5), .bool(true), .null]),
            "nested": .object(["k": .string("v")]),
        ])
        let text = value.description
        let decoded = try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
        #expect(decoded == value)
    }

    @Test
    func jsonEscapesStrings() {
        let s: JSON = .string("he said \"hi\"\nand left")
        let text = s.description
        #expect(text.contains("\\\""))
        #expect(text.contains("\\n"))
    }

    @Test
    func jsonEscapesControlCharactersValidly() throws {
        // Shell output is full of ANSI escapes (ESC is U+001B).
        let value: JSON = .string("\u{1B}[31mred\u{1B}[0m")
        #expect(value.description == "\"\\u001B[31mred\\u001B[0m\"")
        let decoded = try JSONDecoder().decode(JSON.self, from: Data(value.description.utf8))
        #expect(decoded == value)
    }

    @Test
    func messageTextConcatenates() {
        let m = Message(role: .assistant, content: [.text("Hello, "), .text("world!")])
        #expect(m.text == "Hello, world!")
    }

    @Test
    func toolCallResultAsMessage() {
        let r = ToolCallResult(callID: "c1", name: "echo", content: "hi")
        let m = r.asMessage
        #expect(m.role == .tool)
        guard case .toolResult(let result)? = m.content.first else {
            Issue.record("expected toolResult")
            return
        }
        #expect(result.callID == "c1")
        #expect(result.name == "echo")
    }

    @Test
    func sessionAppends() {
        var s = Session(id: "s1")
        s.append(Message(role: .user, text: "hi"))
        #expect(s.messages.count == 1)
        #expect(s.messages.first?.role == .user)
    }

    @Test
    func registryLooksUpByName() {
        struct TestTool: Tool {
            var definition: ToolDefinition { ToolDefinition(name: "test", description: "") }
            func run(arguments: JSON) async throws -> String { "" }
        }
        let registry = ToolRegistry([TestTool()])
        #expect(registry.tool(named: "test") != nil)
        #expect(registry.tool(named: "missing") == nil)
        #expect(registry.definitions.count == 1)
    }
}
