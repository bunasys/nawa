@testable import AgentACP
import Foundation
import Testing

/// `InputLines` reads stdin for the stdio transport on Linux; tested here
/// on every platform.
struct InputLinesTests {
    private func lines(fromWrites writes: [String]) async throws -> [String] {
        let pipe = Pipe()
        let lines = InputLines(pipe.fileHandleForReading)
        Task.detached {
            for write in writes {
                pipe.fileHandleForWriting.write(Data(write.utf8))
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? pipe.fileHandleForWriting.close()
        }
        var out: [String] = []
        for try await line in lines { out.append(line) }
        return out
    }

    @Test(.timeLimit(.minutes(1)))
    func linesSplitAcrossAndWithinWritesComeOutWhole() async throws {
        let out = try await lines(fromWrites: [#"{"a":"#, "1}\n{\"b\":2}\r\n\n", "{\"c\":3}\n"])
        #expect(out == [#"{"a":1}"#, #"{"b":2}"#, "", #"{"c":3}"#])
    }

    @Test(.timeLimit(.minutes(1)))
    func aLastLineWithoutNewlineIsKeptAndEndOfFileEnds() async throws {
        let out = try await lines(fromWrites: ["one\nlast"])
        #expect(out == ["one", "last"])
    }

    @Test(.timeLimit(.minutes(1)))
    func multiByteCharactersSplitBetweenWritesSurvive() async throws {
        let bytes = Array("é中\n".utf8)
        let pipe = Pipe()
        let lines = InputLines(pipe.fileHandleForReading)
        Task.detached {
            for byte in bytes {
                pipe.fileHandleForWriting.write(Data([byte]))
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? pipe.fileHandleForWriting.close()
        }
        var out: [String] = []
        for try await line in lines { out.append(line) }
        #expect(out == ["é中"])
    }

    @Test(.timeLimit(.minutes(1)))
    func dataArrivingTogetherWithEndOfFileStillEnds() async throws {
        // What hung `nawa acp` on Linux: everything written and closed at
        // once. A race, so try it many times.
        for round in 0..<200 {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data("{\"round\":\(round)}\n".utf8))
            try pipe.fileHandleForWriting.close()
            var out: [String] = []
            for try await line in InputLines(pipe.fileHandleForReading) { out.append(line) }
            #expect(out == ["{\"round\":\(round)}"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func devNullIsAnEmptyInput() async throws {
        let handle = try #require(FileHandle(forReadingAtPath: "/dev/null"))
        var out: [String] = []
        for try await line in InputLines(handle) { out.append(line) }
        #expect(out.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRegularFileIsReadToTheEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("input-lines-\(UUID().uuidString).jsonl")
        try Data("a\nb\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        var out: [String] = []
        for try await line in InputLines(handle) { out.append(line) }
        #expect(out == ["a", "b"])
    }
}
