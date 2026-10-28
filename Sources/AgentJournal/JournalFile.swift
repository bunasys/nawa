import AgentCore
import Foundation

/// A session journal stored as a JSON Lines file (proposal 0005).
///
/// Each record is appended as one line with a single write, right away: it
/// costs microseconds next to a model call, and a crash loses at most what
/// the OS hadn't flushed. The file is synced to disk when a run finishes.
///
/// A journal that can't write reports it once through `onFailure` and stops
/// recording; the run goes on. One writer per file: two processes appending
/// to the same journal would interleave their sequence numbers.
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

    /// Flushes and closes the file. Later records reopen it.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    private func openedHandle() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        // Journals hold everything the model saw: readable by their owner only.
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: url.path) {
            nextSeq = (JournalReader.read(url).lines.last?.seq ?? 0) + 1
        } else {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forUpdating: url)
        let end = try handle.seekToEnd()
        // A crash can leave a cut-off last line. Start on a fresh line so
        // only that line is lost, not the first new record too.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if lastByte != Data([UInt8(ascii: "\n")]) {
                try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            }
        }
        self.handle = handle
        return handle
    }
}
