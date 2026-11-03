import AgentCore
@testable import AgentTools
import Foundation
import Testing

/// Line endings, stopping commands, file modes and argument edge cases.
struct CRLFTests {
    @Test
    func readFileSplitsCRLFLines() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "one\r\ntwo\r\nthree\r\n".write(to: directory.appendingPathComponent("dos.txt"), atomically: true, encoding: .utf8)

        let output = try await ReadFileTool(workingDirectory: directory).run(arguments: .object(["path": .string("dos.txt"), "offset": .int(2)]))

        #expect(output == "2\ttwo\n3\tthree")
    }

    @Test
    func capturedOutputCapsCRLFOutput() {
        let text = (1...300).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"

        let capped = CapturedOutput.capped(text, fullOutputAt: "/log")

        #expect(capped.split(separator: "\n").count < 130)
        #expect(capped.hasPrefix("line 1\nline 2\n"))
        #expect(capped.contains("lines omitted; full output at /log]"))
    }

    @Test(.enabled(if: FileWalkParityTests.hasRipgrep))
    func searchCountsCRLFMatchesOneByOne() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = (1...150).map { "hit \($0)" }.joined(separator: "\r\n") + "\r\n"
        try text.write(to: directory.appendingPathComponent("dos.txt"), atomically: true, encoding: .utf8)

        let output = try await SearchTool(workingDirectory: directory).run(arguments: .object(["pattern": .string("hit")]))

        #expect(output.hasPrefix("./dos.txt:1:hit 1\n./dos.txt:2:hit 2\n"))
        #expect(output.contains("[showing matches 1-100 of 150"))
        #expect(!output.contains("\r"))
    }
}

struct ShellStoppingTests {
    /// Whether `pid` is gone; a zombie (exited, not yet reaped) counts as gone.
    func isGone(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty || state.hasPrefix("Z")
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingStopsTheCommandAndWhatItStarted() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let tool = ShellTool(workingDirectory: directory)

        let started = ContinuousClock.now
        let run = Task {
            try await tool.run(arguments: .object(["command": .string("sleep 30 & echo $! > pid.tmp; mv pid.tmp pid; wait")]))
        }
        try await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try #require(Int32(pidText))
        run.cancel()

        let result = await run.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - started < .seconds(10))
        try await waitUntil { isGone(grandchild) }
        #expect(isGone(grandchild))
    }

    @Test(.timeLimit(.minutes(1)))
    func aCommandPastItsTimeoutIsStopped() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ShellTool().run(arguments: .object(["command": .string("echo begun; sleep 30"), "timeout_seconds": .int(1)]))
            Issue.record("expected a timeout")
        } catch let error as ToolError {
            #expect("\(error)".hasPrefix("timed out after 1 seconds; the command and the processes it started were stopped\nbegun"))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test
    func aSignalDeathIsNotAnExitCode() async throws {
        do {
            _ = try await ShellTool().run(arguments: .object(["command": .string("kill -9 $$")]))
            Issue.record("expected the command to fail")
        } catch let error as ToolError {
            #expect("\(error)".hasPrefix("killed by signal 9\n"))
        }
    }
}

struct CaptureFileTests {
    @Test
    func logsArePrivate() async throws {
        let run = try await CapturedOutput.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo secret"], in: URL(fileURLWithPath: "/"))
        defer { run.removeFiles() }

        let file = try FileManager.default.attributesOfItem(atPath: run.logFile.path)
        let folder = try FileManager.default.attributesOfItem(atPath: run.logFile.deletingLastPathComponent().path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(run.output == "secret\n")
    }

    @Test
    func aCommandThatCannotStartLeavesNoLog() async throws {
        let logs = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }

        await #expect(throws: (any Error).self) {
            _ = try await CapturedOutput.run(
                URL(fileURLWithPath: "/nonexistent/tool"), [], in: URL(fileURLWithPath: "/"), separateErrors: true, logsIn: logs
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
    }

    /// Over `wholeReadLimit` the log is read at both ends only; the counts stay exact.
    @Test
    func aLargeLogKeepsHeadAndTailWithAnExactCount() async throws {
        let output = try await ShellTool().run(arguments: .object(["command": .string("seq 1 200000")]))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[1] == "1")
        #expect(lines[40] == "40")
        #expect(lines.dropLast().last == "200000")
        let marker = try #require(lines.first { $0.hasPrefix("[… ") })
        #expect(marker.hasPrefix("[… 199881 lines omitted; full output at "))
        let path = try #require(marker.split(separator: " ").last?.dropLast())
        try? FileManager.default.removeItem(atPath: String(path))
    }
}

struct PathTests {
    @Test
    func tildeMeansTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = URL(fileURLWithPath: "/work")

        #expect(resolvedPath("~", in: root) == home)
        #expect(resolvedPath("~/notes.md", in: root) == home.appendingPathComponent("notes.md"))
        #expect(resolvedPath("~notes", in: root) == root.appendingPathComponent("~notes"))
        #expect(resolvedPath("/etc/hosts", in: root).path == "/etc/hosts")
    }

    @Test
    func findsExecutablesOnThePath() {
        #expect(findExecutable(named: "sh", searchPath: "/nonexistent:/bin")?.path == "/bin/sh")
        #expect(findExecutable(named: "no-such-tool-here", searchPath: "/bin:/usr/bin") == nil)
    }
}

struct ReadFileEdgeCaseTests {
    @Test
    func aHugeLimitDoesNotOverflow() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "a\nb\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let output = try await ReadFileTool(workingDirectory: directory).run(arguments: .object([
            "path": .string("f.txt"), "offset": .int(2), "limit": .int(Int.max),
        ]))

        #expect(output == "2\tb")
    }

    @Test
    func cutLinesSayHowToReadTheRest() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = String(repeating: "x", count: 800)
        try "short\n\(long)\n".write(to: directory.appendingPathComponent("min.json"), atomically: true, encoding: .utf8)

        let output = try await ReadFileTool(workingDirectory: directory).run(arguments: .object(["path": .string("min.json")]))

        let lines = output.split(separator: "\n")
        #expect(lines[1] == "2\t" + String(repeating: "x", count: ReadFileTool.maxLineLength) + " […]")
        #expect(lines.last == "[lines longer than 500 characters were cut (2); read the rest of one with shell, e.g. sed -n '2p' min.json | cut -c 501-5500]")
    }
}

struct EditFileEdgeCaseTests {
    func edit(_ path: String, _ old: String, _ new: String, in directory: URL) async throws -> String {
        try await EditFileTool(workingDirectory: directory).run(arguments: .object([
            "path": .string(path), "old_string": .string(old), "new_string": .string(new),
        ]))
    }

    @Test
    func editsThroughASymlinkAndKeepsPermissions() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("run.sh")
        let link = directory.appendingPathComponent("link.sh")
        try "echo old\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try await edit("link.sh", "old", "new", in: directory)

        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(linkType == .typeSymbolicLink)
        #expect(try String(contentsOf: target, encoding: .utf8) == "echo new\n")
        #expect(mode?.intValue == 0o755)
    }

    @Test
    func fillsAnEmptyFileButNotOneWithText() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("empty.txt").path, contents: nil)

        _ = try await edit("empty.txt", "", "hello", in: directory)

        #expect(try String(contentsOf: directory.appendingPathComponent("empty.txt"), encoding: .utf8) == "hello")
        await #expect(throws: ToolError.self) { _ = try await edit("empty.txt", "", "again", in: directory) }
    }

    @Test
    func aMissingFileIsReportedAsMissing() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await edit("nope.txt", "a", "b", in: directory)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect("\(error)".contains("nope.txt does not exist"))
        }
    }

    @Test
    func matchingIsLiteral() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.txt")
        try "caf\u{E9}\n".write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: ToolError.self) { _ = try await edit("f.txt", "cafe\u{301}", "tea", in: directory) }
        _ = try await edit("f.txt", "caf\u{E9}", "tea", in: directory)
        #expect(try String(contentsOf: file, encoding: .utf8) == "tea\n")
    }
}

struct SearchEdgeCaseTests {
    @Test(.enabled(if: FileWalkParityTests.hasRipgrep))
    func aPathStartingWithADashIsAPath() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "alpha\n".write(to: directory.appendingPathComponent("-x.txt"), atomically: true, encoding: .utf8)

        let found = try await SearchTool(workingDirectory: directory).run(arguments: .object(["pattern": .string("alpha"), "path": .string("-x.txt")]))
        let listed = try await ListFilesTool(workingDirectory: directory).run(arguments: .object(["path": .string("-x.txt")]))

        #expect(found == "-x.txt:1:alpha")
        #expect(listed == "-x.txt")
    }

    /// One unreadable folder must not hide the matches everywhere else.
    @Test(.enabled(if: FileWalkParityTests.hasRipgrep && getuid() != 0))
    func ripgrepErrorsKeepTheMatches() async throws {
        let directory = try makeScratchDirectory()
        let locked = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "alpha\n".write(to: directory.appendingPathComponent("open.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let found = try await SearchTool(workingDirectory: directory).run(arguments: .object(["pattern": .string("alpha")]))
        let listed = try await ListFilesTool(workingDirectory: directory).run(arguments: .object([:]))

        #expect(found.hasPrefix("./open.txt:1:alpha\n[rg reported errors; results may be incomplete. First: "))
        #expect(listed.hasPrefix("./open.txt\n[rg reported errors"))
    }
}

struct ToolSearchEdgeCaseTests {
    @Test
    func oneLetterWordsMatchNothing() async throws {
        let tools: [any Tool] = [DeferredToolsTests.Greeter(), CurrentTimeTool()]

        let found = try await ToolSearchTool(tools: tools).run(arguments: .object(["query": .string("a x hello")]))

        #expect(found.hasPrefix("srv__greet"))
        #expect(!found.contains("current_time"))
    }
}
