#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// A terminal's size in character cells.
public struct TerminalSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// What the inline UI needs from a terminal. `Terminal` is the real one;
/// tests use an in-memory stand-in.
@MainActor
protocol TerminalIO: AnyObject {
    var size: TerminalSize { get }
    /// Writes a whole frame with one `write(2)`.
    func write(_ text: String)
    /// Ctrl-Z: give the terminal back, stop the process, take it again on `fg`.
    func suspend()
}

/// The only place that touches termios, ioctl and signals.
///
/// Raw mode keeps `OPOST`, so a stray `\n` from elsewhere still moves to
/// the start of the next line. The saved settings are restored on normal
/// exit, on `SIGTERM` / `SIGHUP` (an ssh disconnect) and through `atexit`;
/// `SIGINT` can't arrive in raw mode, Ctrl-C is read as a key.
@MainActor
final class Terminal: TerminalIO {
    /// What the terminal reports besides keys.
    enum Signal: Sendable {
        case resized
        /// The process was stopped and continued (`fg`): redraw everything.
        case resumed
    }

    private let input: Int32 = STDIN_FILENO
    private let output: Int32 = STDOUT_FILENO
    private var signalSources: [any DispatchSourceSignal] = []

    /// Whether stdin and stdout are a terminal worth drawing on.
    nonisolated static func isInteractive(environment: [String: String]) -> Bool {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return false }
        let term = environment["TERM"] ?? ""
        return !term.isEmpty && term != "dumb"
    }

    var size: TerminalSize {
        Self.currentSize() ?? TerminalSize(columns: 80, rows: 24)
    }

    /// The size of the terminal on stdout, asked fresh (ssh forwards
    /// window changes, so it can change at any time); nil without one.
    nonisolated static func currentSize() -> TerminalSize? {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0, window.ws_col > 0 else { return nil }
        return TerminalSize(columns: Int(window.ws_col), rows: max(Int(window.ws_row), 1))
    }

    /// Enters raw mode, turns on bracketed paste, and starts listening for
    /// resizes and termination signals.
    func start(signals: @escaping @Sendable (Signal) -> Void) throws(TerminalError) {
        var settings = termios()
        guard tcgetattr(input, &settings) == 0 else { throw TerminalError.notATerminal }
        TerminalState.save(settings)
        atexit { TerminalState.restore() }
        try enterRawMode()
        rawWrite(Escape.bracketedPasteOn)

        watch(SIGWINCH) { signals(.resized) }
        watch(SIGCONT) {
            // A shell restores its own settings when it stops a job: take raw mode back.
            TerminalState.reenterRaw()
            signals(.resumed)
        }
        for signal in [SIGTERM, SIGHUP] {
            watch(signal) {
                TerminalState.restore()
                exit(128 + signal)
            }
        }
    }

    /// Restores the terminal as it was before `start`.
    func stop() {
        for source in signalSources { source.cancel() }
        signalSources = []
        TerminalState.restore()
    }

    func write(_ text: String) {
        rawWrite(text)
    }

    func suspend() {
        TerminalState.restore()
        // The default action stops the process; `kill` returns once it is continued.
        signal(SIGTSTP, SIG_DFL)
        kill(getpid(), SIGTSTP)
        signal(SIGTSTP, SIG_IGN)
        TerminalState.reenterRaw()
    }

    private func enterRawMode() throws(TerminalError) {
        guard TerminalState.reenterRaw() else { throw TerminalError.notATerminal }
    }

    private func rawWrite(_ text: String) {
        TerminalState.write(text, to: output)
    }

    private func watch(_ number: Int32, _ handler: @escaping @Sendable () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }

    // MARK: - Reading keys

    /// Keys typed at the terminal, read on a thread of their own. A lone
    /// Esc is told apart from the start of a sequence by waiting 50 ms for
    /// more bytes. The stream ends when stdin does.
    nonisolated static func keys() -> AsyncStream<[Key]> {
        AsyncStream { continuation in
            let reader = KeyReader(fd: STDIN_FILENO, continuation: continuation)
            continuation.onTermination = { _ in reader.stop() }
            reader.start()
        }
    }
}

enum TerminalError: Error, CustomStringConvertible {
    case notATerminal

    var description: String { "stdin is not a terminal" }
}

/// The settings to restore, global so `atexit` and signal handlers can
/// reach them. Guarded by a lock: signals arrive on other threads.
private enum TerminalState {
    nonisolated(unsafe) private static var saved: termios?
    nonisolated(unsafe) private static var isRaw = false
    nonisolated(unsafe) private static var lock = pthread_mutex_t()
    private static let lockReady: Void = { pthread_mutex_init(&lock, nil) }()

    private static func locked<T>(_ body: () -> T) -> T {
        _ = lockReady
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return body()
    }

    static func save(_ settings: termios) {
        locked { if saved == nil { saved = settings } }
    }

    /// `cfmakeraw` minus `OPOST`: no echo, no line buffering, no signals
    /// from Ctrl-C / Ctrl-Z, bytes delivered as they arrive.
    @discardableResult
    static func reenterRaw() -> Bool {
        locked {
            guard var raw = saved else { return false }
            raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
            raw.c_cflag |= tcflag_t(CS8)
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
            isRaw = true
            return true
        }
    }

    /// Cooked mode back, cursor shown, bracketed paste off. Safe to call twice.
    static func restore() {
        locked {
            guard isRaw, var settings = saved else { return }
            write(Escape.bracketedPasteOff + Escape.showCursor, to: STDOUT_FILENO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings)
            isRaw = false
        }
    }

    static func write(_ text: String, to fd: Int32) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { systemWrite(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return  // the terminal is gone (ssh hung up): nothing to do
            }
            bytes = bytes.dropFirst(written)
        }
    }
}

/// `write(2)`, under a name the methods called `write` don't shadow.
private func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, bytes, count)
}

/// Reads stdin on its own thread and decodes keys there, so a key sequence
/// split across reads is put back together before the app sees it.
private final class KeyReader: @unchecked Sendable {
    private let fd: Int32
    private let continuation: AsyncStream<[Key]>.Continuation
    /// Written to by `stop()` to wake the reader out of `poll`.
    private var wake: [Int32] = [-1, -1]

    init(fd: Int32, continuation: AsyncStream<[Key]>.Continuation) {
        self.fd = fd
        self.continuation = continuation
        _ = pipe(&wake)
    }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.start()
    }

    func stop() {
        var byte: UInt8 = 0
        _ = systemWrite(wake[1], &byte, 1)
    }

    private func readLoop() {
        var decoder = KeyDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer {
            close(wake[0])
            close(wake[1])
            continuation.finish()
        }
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, decoder.hasPending ? 50 : -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            if ready == 0 {
                let keys = decoder.flush()
                if !keys.isEmpty { continuation.yield(keys) }
                continue
            }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return }  // end of input
            let keys = decoder.decode(buffer[0..<count])
            if !keys.isEmpty { continuation.yield(keys) }
        }
    }
}
