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
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ROOT".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "NESTED".write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = try ProjectInstructions.load(from: nested)
        #expect(loaded?.text.contains("ROOT") == true)
        #expect(loaded?.text.contains("NESTED") == true)
        // Root appears before nested (root first, nearest last).
        #expect(loaded?.text.range(of: "ROOT")?.lowerBound ?? String.Index(utf16Offset: -1, in: loaded!.text) < loaded!.text.range(of: "NESTED")!.lowerBound)
    }

    /// Like SOUL.md and skills: another user's /tmp/AGENTS.md must not
    /// reach every session started under /tmp.
    @Test
    func theChainStopsAtTheGitRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = outside.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "OUTSIDE".write(to: outside.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "REPO".write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        // Without a git repository, only the directory itself.
        #expect(try ProjectInstructions.load(from: nested) == nil)

        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let loaded = try ProjectInstructions.load(from: nested)
        #expect(loaded?.text == "REPO")
    }

    /// A FIFO would hang startup; a directory, a huge file or one that
    /// isn't UTF-8 used to sink the whole chain.
    @Test
    func filesThatArentTextAreSkippedAndTheRestLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fifoDir = root.appendingPathComponent("a")
        let folderDir = fifoDir.appendingPathComponent("b")
        let hugeDir = folderDir.appendingPathComponent("c")
        let binaryDir = hugeDir.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ROOT".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        #expect(mkfifo(fifoDir.appendingPathComponent("AGENTS.md").path, 0o600) == 0)
        try FileManager.default.createDirectory(at: folderDir.appendingPathComponent("AGENTS.md"), withIntermediateDirectories: true)
        try String(repeating: "x", count: 300 * 1024).write(to: hugeDir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binaryDir.appendingPathComponent("AGENTS.md"))

        let loaded = try ProjectInstructions.load(from: binaryDir)
        #expect(loaded?.text == "ROOT")
        #expect(loaded?.files == [root.appendingPathComponent("AGENTS.md")])
    }

    @Test
    func aFIFONamedSoulIsSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(mkfifo(directory.appendingPathComponent("SOUL.md").path, 0o600) == 0)
        let prompt = SystemPrompt.load(for: directory, environment: ["HOME": directory.path], skills: false)
        #expect(!prompt.text.contains("Project persona"))
    }

    @Test
    func governsComparesWholePathComponents() throws {
        let instructions = try #require(ProjectInstructions(
            nearest: URL(fileURLWithPath: "/a/b/AGENTS.md"),
            files: [URL(fileURLWithPath: "/a/b/AGENTS.md")],
            text: ""
        ))
        #expect(instructions.governs(URL(fileURLWithPath: "/a/b/x.swift")))
        #expect(instructions.governs(URL(fileURLWithPath: "/a/b")))
        #expect(!instructions.governs(URL(fileURLWithPath: "/a/bc/x.swift")))
        #expect(!instructions.governs(URL(fileURLWithPath: "/elsewhere/AGENTS.md")))
    }
}
