import Foundation
import Synchronization

/// Running a command and keeping its output small enough to send to a model.
///
/// Tool output is resent with every later turn, so one long build log can
/// cost more than the rest of the conversation. Long output is cut to its
/// first and last lines; the full text stays in a log file the agent can
/// search or read if it needs more.
enum CapturedOutput {
    static let headLines = 40
    /// Builds and tests print their verdict at the end, so the tail gets more room.
    static let tailLines = 80
    /// Minified files and generated code can put megabytes on one line.
    static let maxLineLength = 500
    /// Logs up to this size are read whole; bigger ones only at both ends,
    /// so a gigabyte of output never sits in memory.
    static let wholeReadLimit = 256 * 1024
    static let edgeReadSize = 64 * 1024
    /// How long a stopped command gets to exit on SIGTERM before SIGKILL.
    static let stopGracePeriod = 2.0

    enum Ending: Equatable {
        case exited(Int32)
        case killedBySignal(Int32)
        case timedOut(seconds: Int)
    }

    struct Run {
        var ending: Ending
        /// stdout, plus stderr unless it was asked for separately.
        var logFile: URL
        /// stderr, when it was asked for separately.
        var errorFile: URL?

        /// The exit code, or nil when the command didn't exit by itself.
        var exitCode: Int32? {
            if case .exited(let code) = ending { return code }
            return nil
        }

        var output: String { readWhole(logFile) }
        var errors: String { errorFile.map(readWhole) ?? "" }

        func removeFiles() {
            try? FileManager.default.removeItem(at: logFile)
            if let errorFile { try? FileManager.default.removeItem(at: errorFile) }
        }
    }

    /// Runs `executable` with `arguments` until it exits, is cancelled or
    /// runs past `timeout`.
    ///
    /// Output goes to a file rather than a pipe: waiting for the process to
    /// exit before draining a pipe deadlocks once the output fills the pipe
    /// buffer (64 KB).
    ///
    /// Foundation starts the child in a process group of its own (on macOS
    /// and Linux alike), so stopping it signals the whole group: commands
    /// the child started stop too instead of living on as orphans.
    /// Cancelling the task stops the command and throws `CancellationError`.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL,
        timeout: Duration? = nil,
        separateErrors: Bool = false,
        logsIn logs: URL = logDirectory()
    ) async throws -> Run {
        let logFile = logs.appendingPathComponent("nawa-\(UUID().uuidString.prefix(8)).log")
        let logHandle = try createPrivateFile(logFile)
        defer { try? logHandle.close() }
        var errorFile: URL?
        var errorHandle: FileHandle?
        if separateErrors {
            let url = logFile.deletingPathExtension().appendingPathExtension("err")
            do {
                errorHandle = try createPrivateFile(url)
            } catch {
                try? FileManager.default.removeItem(at: logFile)
                throw error
            }
            errorFile = url
        }
        defer { try? errorHandle?.close() }
        let run = Run(ending: .exited(0), logFile: logFile, errorFile: errorFile)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = logHandle
        process.standardError = errorHandle ?? logHandle
        process.standardInput = FileHandle.nullDevice

        let child = ChildProcess(process)
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                child.stop(timedOut: true)
            }
        }
        defer { timer?.cancel() }

        do {
            try await child.runUntilExit()
        } catch {
            run.removeFiles()
            throw error
        }
        if Task.isCancelled {
            run.removeFiles()
            throw CancellationError()
        }

        var finished = run
        if child.didTimeOut, let timeout {
            finished.ending = .timedOut(seconds: Int(timeout.components.seconds))
        } else if process.terminationReason == .uncaughtSignal {
            finished.ending = .killedBySignal(process.terminationStatus)
        } else {
            finished.ending = .exited(process.terminationStatus)
        }
        return finished
    }

    /// The run's output, cut to its head and tail when long. The log file
    /// is deleted when nothing was cut and kept (and named) when something was.
    static func capped(_ run: Run) -> String {
        let path = run.logFile.path
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > wholeReadLimit {
            return cappedLargeLog(at: run.logFile, size: size)
        }
        let output = run.output
        let capped = capped(output, fullOutputAt: path)
        if capped == output {
            try? FileManager.default.removeItem(at: run.logFile)
        }
        return capped
    }

    static func capped(_ text: String, fullOutputAt path: String) -> String {
        let lines = splitLines(text)
        let shortened = lines.map(shortened)
        let hasLongLines = shortened != lines
        let hasTooManyLines = lines.count > headLines + tailLines
        guard hasLongLines || hasTooManyLines else { return text }

        guard hasTooManyLines else {
            return shortened.joined(separator: "\n") + "\n[long lines shortened; full output at \(path)]"
        }
        let omitted = lines.count - headLines - tailLines
        let marker = "[… \(omitted) lines omitted; full output at \(path)]"
        return (shortened.prefix(headLines) + [Substring(marker)] + shortened.suffix(tailLines)).joined(separator: "\n")
    }

    /// Head and tail of a log too big to read whole: the first and last
    /// `edgeReadSize` bytes, with the lines in between counted, not kept.
    private static func cappedLargeLog(at url: URL, size: Int) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        let headBytes = (try? file.read(upToCount: edgeReadSize)) ?? Data()
        try? file.seek(toOffset: UInt64(size - edgeReadSize))
        let tailBytes = (try? file.read(upToCount: edgeReadSize)) ?? Data()
        try? file.seek(toOffset: 0)
        let lineCount = countNewlines(in: file) + 1

        // The chunks start and end mid-line: the head's last piece is marked
        // as cut, and the tail's first piece is dropped.
        var head = splitLines(String(decoding: headBytes, as: UTF8.self)).prefix(headLines + 1).map(shortened)
        if head.count > headLines {
            head.removeLast()
        } else if let last = head.popLast() {
            head.append(last.hasSuffix(" […]") ? last : Substring(last + " […]"))
        }
        let tail = splitLines(String(decoding: tailBytes, as: UTF8.self)).dropFirst().suffix(tailLines).map(shortened)

        let omitted = max(0, lineCount - head.count - tail.count)
        let marker = "[… \(omitted) lines omitted; full output at \(url.path)]"
        return (head + [Substring(marker)] + tail).joined(separator: "\n")
    }

    private static func countNewlines(in file: FileHandle) -> Int {
        var count = 0
        while let chunk = try? file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += chunk.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        }
        return count
    }

    private static func shortened(_ line: Substring) -> Substring {
        line.count > maxLineLength ? line.prefix(maxLineLength) + " […]" : line
    }

    private static func readWhole(_ url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where logs go: a `nawa-<uid>` folder in the temp directory that only
    /// this user can enter. On Linux the temp directory is a shared `/tmp`,
    /// and logs hold whatever commands print, secrets included. If the
    /// folder exists but isn't this user's own directory (someone else
    /// made it first, or it is a symlink), a fresh private folder is used.
    static func logDirectory() -> URL {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        let shared = temp.appendingPathComponent("nawa-\(getuid())")
        try? fileManager.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        // attributesOfItem doesn't follow symlinks, so a planted link shows as one.
        let attributes = (try? fileManager.attributesOfItem(atPath: shared.path)) ?? [:]
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let isOurs = isDirectory && owner == getuid()
        if isOurs {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            if mode != 0o700 {
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path)
            }
            return shared
        }

        let fresh = temp.appendingPathComponent("nawa-\(getuid())-\(UUID().uuidString.prefix(8))")
        try? fileManager.createDirectory(at: fresh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return fresh
    }

    /// A new file only its owner can read. `O_EXCL` refuses an existing
    /// file or symlink at that path.
    private static func createPrivateFile(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// A started process that can be stopped from another task: on
/// cancellation or timeout, while `runUntilExit` waits.
private final class ChildProcess: Sendable {
    // Process isn't Sendable; every use after start goes through `state`.
    nonisolated(unsafe) let process: Process
    private let state = Mutex(State())

    private struct State {
        var pid: Int32 = 0
        var exited = false
        var timedOut = false
    }

    init(_ process: Process) {
        self.process = process
    }

    var didTimeOut: Bool { state.withLock { $0.timedOut } }

    /// Waits for the process without blocking a thread: cooperative
    /// threads are few, and a hung command must not starve the others.
    func runUntilExit() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in
                    self.state.withLock { $0.exited = true }
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                let pid = process.processIdentifier
                state.withLock { $0.pid = pid }
                // A cancel that came before the pid was known found nothing to stop.
                if Task.isCancelled { stop() }
            }
        } onCancel: {
            stop()
        }
    }

    /// SIGTERM to the process group, then SIGKILL after a grace period for
    /// whatever ignored it.
    func stop(timedOut: Bool = false) {
        let pid = state.withLock { state -> Int32 in
            if timedOut && !state.exited { state.timedOut = true }
            return state.exited ? 0 : state.pid
        }
        // pid 0 would signal our own process group.
        guard pid > 0 else { return }
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + CapturedOutput.stopGracePeriod) {
            kill(target, SIGKILL)
        }
    }
}
