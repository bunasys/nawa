import AgentInstructions
import Foundation
import Testing

struct AgentInstructionsTests {
    @Test
    func loadsNearestAgentsMD() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let agentsMD = tmp.appendingPathComponent("AGENTS.md")
        try "# Test\nDo good things.".write(to: agentsMD, atomically: true, encoding: .utf8)
        let loaded = try ProjectInstructions.load(from: tmp)
        #expect(loaded != nil)
        #expect(loaded?.text.contains("Do good things.") == true)
        #expect(loaded?.nearest == agentsMD)
    }

    @Test
    func returnsNilWhenNoAgentsMD() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loaded = try ProjectInstructions.load(from: tmp)
        #expect(loaded == nil)
    }

    @Test
    func nestedFilesConcatenateRootFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ROOT".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "NESTED".write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = try ProjectInstructions.load(from: nested)
        #expect(loaded?.text.contains("ROOT") == true)
        #expect(loaded?.text.contains("NESTED") == true)
        // Root appears before nested (root first, nearest last).
        #expect(loaded?.text.range(of: "ROOT")?.lowerBound ?? String.Index(utf16Offset: -1, in: loaded!.text) < loaded!.text.range(of: "NESTED")!.lowerBound)
    }
}
