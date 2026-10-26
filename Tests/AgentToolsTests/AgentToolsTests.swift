import AgentCore
@testable import AgentTools
import Foundation
import Testing

/// A fresh directory per test, removed afterwards.
func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ShellToolTests {
    @Test
    func shortOutputIsReturnedWhole() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await ShellTool(workingDirectory: directory).run(arguments: .object(["command": .string("pwd")]))
        #expect(output.hasPrefix("exit code: 0\n"))
        #expect(output.contains(directory.lastPathComponent))
    }

    @Test
    func longOutputKeepsHeadAndTailAndSavesTheRest() async throws {
        // 200 KB of output also proves the tool no longer deadlocks on a full pipe.
        let output = try await ShellTool().run(arguments: .object(["command": .string("seq 1 40000")]))
        let lines = output.split(separator: "\n")
        #expect(lines.count < 130)
        #expect(lines[1] == "1")
        #expect(lines.last == "40000")

        let marker = try #require(lines.first { $0.hasPrefix("[… ") })
        let path = try #require(marker.split(separator: " ").last?.dropLast())
        let saved = try String(contentsOfFile: String(path), encoding: .utf8)
        #expect(saved.split(separator: "\n").count == 40000)
        try? FileManager.default.removeItem(atPath: String(path))
    }

    @Test
    func failureThrowsWithExitCodeAndPlainMessage() async throws {
        do {
            _ = try await ShellTool().run(arguments: .object(["command": .string("echo oops; exit 3")]))
            Issue.record("expected the command to fail")
        } catch let error as ToolError {
            #expect("\(error)" == "exit code: 3\noops\n")
        }
    }
}

struct ReadFileToolTests {
    @Test
    func readsANumberedWindow() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "a\nb\nc\nd\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let tool = ReadFileTool(workingDirectory: directory)
        let output = try await tool.run(arguments: .object(["path": .string("f.txt"), "offset": .int(2), "limit": .int(2)]))
        #expect(output == "2\tb\n3\tc\n[showing lines 2-3 of 4; pass offset 4 to read on]")

        let all = try await tool.run(arguments: .object(["path": .string("f.txt")]))
        #expect(all == "1\ta\n2\tb\n3\tc\n4\td")
    }
}

extension ReadFileToolTests {
    /// Whole files by default: paging costs a model call per page.
    @Test
    func readsAWholeLongFileInOneCall() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = (1...1500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("long.swift"), atomically: true, encoding: .utf8)

        let output = try await ReadFileTool(workingDirectory: directory).run(arguments: .object(["path": .string("long.swift")]))

        #expect(output.split(separator: "\n").count == 1500)
        #expect(output.hasSuffix("1500\tline 1500"))
    }
}

struct EditFileToolTests {
    @Test
    func replacesExactlyOneOccurrence() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.txt")
        try "let a = 1\nlet b = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = EditFileTool(workingDirectory: directory)

        _ = try await tool.run(arguments: .object([
            "path": .string("f.txt"), "old_string": .string("a = 1"), "new_string": .string("a = 2"),
        ]))
        #expect(try String(contentsOf: file, encoding: .utf8) == "let a = 2\nlet b = 1\n")

        await #expect(throws: ToolError.self) {
            try await tool.run(arguments: .object([
                "path": .string("f.txt"), "old_string": .string("= "), "new_string": .string("="),
            ]))
        }
        await #expect(throws: ToolError.self) {
            try await tool.run(arguments: .object([
                "path": .string("f.txt"), "old_string": .string("missing"), "new_string": .string(""),
            ]))
        }
    }

    @Test
    func emptyOldStringCreatesAFileButNeverOverwrites() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = EditFileTool(workingDirectory: directory)
        let create: JSON = .object(["path": .string("new/f.txt"), "old_string": .string(""), "new_string": .string("hi")])

        _ = try await tool.run(arguments: create)
        #expect(try String(contentsOf: directory.appendingPathComponent("new/f.txt"), encoding: .utf8) == "hi")
        await #expect(throws: ToolError.self) { try await tool.run(arguments: create) }
    }
}

struct SearchToolsTests {
    @Test
    func searchAndListFilesUseRipgrep() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "alpha\nbeta\n".write(to: directory.appendingPathComponent("one.swift"), atomically: true, encoding: .utf8)
        try "gamma\n".write(to: directory.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)

        let search = SearchTool(workingDirectory: directory)
        let match = try await search.run(arguments: .object(["pattern": .string("bet")]))
        #expect(match == "./one.swift:2:beta")
        let none = try await search.run(arguments: .object(["pattern": .string("zeta")]))
        #expect(none == "No matches.")

        let list = try await ListFilesTool(workingDirectory: directory).run(arguments: .object(["glob": .string("*.swift")]))
        #expect(list == "./one.swift")
    }
}

struct DeferredToolsTests {
    struct Greeter: Tool {
        var definition: ToolDefinition { ToolDefinition(name: "srv__greet", description: "Say hello to someone.") }
        func run(arguments: JSON) async throws -> String { "hello \(arguments.objectValue?["who"]?.stringValue ?? "")" }
    }

    @Test
    func searchFindsSchemasAndCallRunsTheTool() async throws {
        let tools: [any Tool] = [Greeter(), CurrentTimeTool()]
        let found = try await ToolSearchTool(tools: tools).run(arguments: .object(["query": .string("hello")]))
        #expect(found.hasPrefix("srv__greet: Say hello"))
        #expect(!found.contains("current_time"))

        let output = try await CallToolTool(tools: tools).run(arguments: .object([
            "name": .string("srv__greet"), "arguments": .object(["who": .string("Nawa")]),
        ]))
        #expect(output == "hello Nawa")
    }
}

/// `FileWalk` stands in for ripgrep, so it must give ripgrep's answers.
/// These tests run both and compare; they need rg installed.
struct FileWalkParityTests {
    static let hasRipgrep = (try? CapturedOutput.run(["rg", "--version"], in: URL(fileURLWithPath: "/")))?.status == 0

    func ripgrep(_ arguments: [String], in directory: URL) throws -> [String] {
        let run = try CapturedOutput.run(["rg"] + arguments, in: directory)
        try? FileManager.default.removeItem(at: run.logFile)
        return run.output.split(separator: "\n").map(String.init)
    }

    /// A small repository exercising each ignore rule.
    func makeFixture() throws -> URL {
        let root = try makeScratchDirectory()
        let files = [
            "a.txt": "alpha\n", "a/z.txt": "zeta alpha\n", ".hidden": "alpha\n",
            "build/out.txt": "alpha\n", "sub/keep.log": "alpha\n", "sub/deep/x.log": "alpha\n",
            "sub/deep/y.swift": "let alpha = 1\n", "docs/notes.md": "alpha\n", "docs/private/s.md": "alpha\n",
            "binary.bin": "alpha\u{0}\n", "only-ignore.tmp": "alpha\n", "re[1].txt": "alpha\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try "/build/\n*.log\n!keep.log\n# comment\n\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "private/\n".write(to: root.appendingPathComponent("docs/.gitignore"), atomically: true, encoding: .utf8)
        try "*.tmp\n".write(to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        try "!x.log\n".write(to: root.appendingPathComponent("sub/deep/.ignore"), atomically: true, encoding: .utf8)
        return root
    }

    @Test(.enabled(if: hasRipgrep))
    func listingMatchesRipgrep() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = FileWalk(workingDirectory: root)
        let cases: [(path: String, glob: String?)] = [
            (".", nil), (".", "*.txt"), (".", "!*.txt"), (".", "sub/**/*.swift"), (".", "a/*"),
            ("sub", nil), ("sub/deep", nil), ("docs", "*.md"), ("a.txt", nil),
        ]
        for (path, glob) in cases {
            let expected = try ripgrep(["--files", "--sort=path"] + (glob.map { ["--glob", $0] } ?? []) + [path], in: root)
            let actual = try walk.files(under: path, glob: glob).map(\.display)
            #expect(actual == expected, "path \(path), glob \(glob ?? "none")")
        }
    }

    @Test(.enabled(if: hasRipgrep))
    func searchMatchesRipgrep() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try ripgrep(["--line-number", "--with-filename", "--no-heading", "--sort=path", "--regexp", "alph?a", "."], in: root)
        let actual = try FileWalk(workingDirectory: root).search(pattern: "alph?a", under: ".", glob: nil)
        #expect(actual == expected)
        #expect(!actual.contains { $0.contains("binary.bin") })
    }

    /// A real tree with a real .gitignore: this package.
    @Test(.enabled(if: hasRipgrep))
    func listingThisRepositoryMatchesRipgrep() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = try ripgrep(["--files", "--sort=path", "."], in: repository)
        let actual = try FileWalk(workingDirectory: repository).files(under: ".", glob: nil).map(\.display)
        #expect(actual == expected)
    }

    /// Regression: outside any git repository the search for `.git` climbs
    /// to "/", and once looped forever there. `.gitignore` must not apply.
    @Test(.timeLimit(.minutes(1)))
    func walkOutsideAGitRepositoryEndsAndSkipsGitignore() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a\n".write(to: root.appendingPathComponent("kept.log"), atomically: true, encoding: .utf8)
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let files = try FileWalk(workingDirectory: root).files(under: ".", glob: nil).map(\.display)
        #expect(files == ["./kept.log"])
    }

    @Test
    func globsCompileToGitignoreSemantics() throws {
        func matches(_ glob: String, _ path: String, directory: Bool = false) throws -> Bool {
            try #require(IgnorePattern(glob)).matches(path, isDirectory: directory)
        }
        #expect(try matches("*.log", "deep/down/x.log"))
        #expect(try !matches("/x.log", "deep/x.log"))
        #expect(try matches("a/**/b", "a/b"))
        #expect(try matches("a/**/b", "a/x/y/b"))
        #expect(try matches("a/**", "a/x/y"))
        #expect(try !matches("a/*", "a/x/y"))
        #expect(try matches("re[!0-9].txt", "rex.txt"))
        #expect(try !matches("build/", "build"))
        #expect(try matches("build/", "build", directory: true))
        #expect(IgnorePattern("# comment") == nil)
        #expect(IgnorePattern("   ") == nil)
    }
}
