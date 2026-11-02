import Foundation
import Testing
@testable import nawa

/// `nawa config` asks its questions on stdout before it reads the answer.
/// stdout is a pipe here, so it is fully buffered: without an `fflush` after
/// each question nothing arrives until the buffer fills or the process exits.
@Suite struct ConfigPromptTests {
    @Test func eachQuestionArrivesBeforeTheAnswerIsRead() async throws {
        let binary = try nawaBinary()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nawa-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var environment = ProcessInfo.processInfo.environment
        environment["NAWA_CONFIG_FILE"] = directory.appendingPathComponent("config.json").path
        environment["NAWA_SESSIONS"] = "off"
        let nawa = try NawaConfigProcess(binary: binary, directory: directory, environment: environment)
        defer { nawa.terminate() }

        // Nothing is written to stdin yet: the first question still has to show.
        try await nawa.expect("API (openai/anthropic) [openai]: ", within: .seconds(10))
        nawa.write("anthropic\n")
        try await nawa.expect("Base URL [https://api.anthropic.com]: ", within: .seconds(10))
    }

    /// The executable `swift build --build-tests` puts next to the test bundle.
    private func nawaBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // nawaTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        for configuration in ["debug", "release"] {
            let candidate = root.appendingPathComponent(".build/\(configuration)/nawa")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw NawaConfigProcessError.binaryNotFound
    }
}

private enum NawaConfigProcessError: Error {
    case binaryNotFound
    case timedOut(showing: String)
}

/// The built `nawa config` over pipes, with the output read as it comes.
private final class NawaConfigProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var output = Data()

    init(binary: URL, directory: URL, environment: [String: String]) throws {
        process.executableURL = binary
        process.arguments = ["config"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.withLock { self.output.append(chunk) }
        }
        try process.run()
    }

    func write(_ answer: String) {
        stdinPipe.fileHandleForWriting.write(Data(answer.utf8))
    }

    func expect(_ text: String, within timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        while true {
            let seen = lock.withLock { String(decoding: output, as: UTF8.self) }
            if seen.contains(text) { return }
            if Date() >= deadline {
                throw NawaConfigProcessError.timedOut(showing: seen)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
