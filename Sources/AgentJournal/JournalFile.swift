#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import AgentCore
import Foundation

/// A session journal stored as a JSON Lines file (proposal 0005).
///
/// Each record is appended as one line with a single write, right away: it
/// costs microseconds next to a model call, and a crash loses at most what
/// the OS hadn't flushed. The file is synced to disk when a run finishes.
///
/// A journal that can't write reports it once through `onFailure` and stops
/// recording; the run goes on.
///
/// One writer per file: an open journal holds an exclusive `flock` until it
/// is closed or released, so a second process (or a second `JournalFile`)
/// can't interleave its records. `init(continuing:)` takes the lock up front
/// and throws `JournalFileError.inUse` when another writer has it.
public final class JournalFile: SessionJournal, @unchecked Sendable {
    public let url: URL
    public let origin: JournalOrigin
    private let onFailure: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    /// Opened on the first record, so a session that never runs leaves no file.
    private var handle: FileHandle?
    private var nextSeq = 1
    private var hasFailed = false

    /// - Parameters:
    ///   - url: The journal file. Created with its directory if missing;
    ///     appended to if it exists.
    ///   - onFailure: Told once, in words, when recording stops.
    public init(url: URL, origin: JournalOrigin, onFailure: (@Sendable (String) -> Void)? = nil) {
        self.url = url
        self.origin = origin
        self.onFailure = onFailure
    }

    /// Opens an existing session's journal to go on with it, taking its
    /// lock now: resuming must fail before the session starts, not lose
    /// records later.
    ///
    /// - Throws: `JournalFileError.inUse` when another writer holds the
    ///   journal, or the error opening it.
    public init(continuing url: URL, origin: JournalOrigin, onFailure: (@Sendable (String) -> Void)? = nil) throws {
        self.url = url
        self.origin = origin
        self.onFailure = onFailure
        handle = try openedHandle()
    }

    deinit {
        try? handle?.close()
    }

    public func record(_ entry: JournalEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFailed else { return }
        do {
            let handle = try openedHandle()
            var line = try JournalFormat.encode(entry, seq: nextSeq)
            line.append(UInt8(ascii: "\n"))
            try handle.write(contentsOf: line)
            nextSeq += 1
            if case .runFinished = entry.record {
                try handle.synchronize()
            }
        } catch {
            hasFailed = true
            onFailure?("session journal \(url.path): \(error); recording stopped")
        }
    }

    /// Flushes and closes the file, releasing its lock. Later records
    /// reopen it.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    /// Whether another writer holds the journal at `url` right now. A
    /// missing file is not in use.
    public static func isInUse(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let probe = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? probe.close() }
        // flock locks belong to the open file, so this probe conflicts with
        // a writer in this process too, and closing it drops only its own.
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0
    }

    private func openedHandle() throws -> FileHandle {
        if let handle { return handle }
        try Self.prepareDirectory(url.deletingLastPathComponent())
        // O_APPEND puts every write at the end even if the file grew under
        // us; the mode on O_CREAT makes a new file private from its first byte.
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw JournalFileError.inUse(url)
        }
        let end = try handle.seekToEnd()
        nextSeq = try Self.lastSequenceNumber(in: handle, size: end) + 1
        // A crash can leave a cut-off last line. Start on a fresh line so
        // only that line is lost, not the first new record too.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            if lastByte != Data([UInt8(ascii: "\n")]) {
                try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            }
        }
        self.handle = handle
        return handle
    }

    /// The `seq` of the last line that decodes, read backwards in blocks:
    /// reopening a long session must not decode the whole file.
    static func lastSequenceNumber(in handle: FileHandle, size: UInt64) throws -> Int {
        let blockSize: UInt64 = 64 * 1024
        let newline = UInt8(ascii: "\n")
        var blockEnd = size
        // The start of the line the previous block began in the middle of.
        var carried = Data()
        while blockEnd > 0 {
            let blockStart = blockEnd > blockSize ? blockEnd - blockSize : 0
            try handle.seek(toOffset: blockStart)
            let block = try handle.read(upToCount: Int(blockEnd - blockStart)) ?? Data()
            let buffer = block + carried
            var lines = buffer.split(separator: newline, omittingEmptySubsequences: false)
            // Unless this block starts the file, its first line may begin in an earlier block.
            let reachedStart = blockStart == 0
            carried = reachedStart ? Data() : Data(lines.removeFirst())
            for line in lines.reversed() where !line.isEmpty {
                if let decoded = try? JournalFormat.decode(Data(line)) { return decoded.seq }
            }
            blockEnd = blockStart
        }
        return 0
    }

    /// Creates the journal's directory readable by its owner only. An
    /// existing one of ours is tightened to 0700 too: `createDirectory`
    /// sets the mode only on the folders it creates. Someone else's is
    /// used as it is, with a warning.
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard stat(directory.path, &info) == 0 else { return }
        let isOurs = info.st_uid == getuid()
        guard isOurs else {
            warnOnce(about: directory, "nawa: sessions directory \(directory.path) belongs to another user; journals there may be readable by others")
            return
        }
        let othersCanEnter = Int(info.st_mode) & 0o077 != 0
        if othersCanEnter {
            _ = chmod(directory.path, 0o700)
        }
    }

    private static let warnedLock = NSLock()
    nonisolated(unsafe) private static var warnedDirectories: Set<String> = []

    private static func warnOnce(about directory: URL, _ message: String) {
        warnedLock.lock()
        defer { warnedLock.unlock() }
        guard !warnedDirectories.contains(directory.path) else { return }
        warnedDirectories.insert(directory.path)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

public enum JournalFileError: Error, Equatable, LocalizedError {
    /// Another writer (usually another nawa process) has the journal open.
    case inUse(URL)

    public var errorDescription: String? {
        switch self {
        case .inUse(let url): return "journal \(url.path) is open in another nawa"
        }
    }
}
