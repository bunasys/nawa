import AgentACP
import AgentJournal
import Foundation

/// The command line of `nawa serve` and `nawa connect`: where the server
/// listens and the bearer token that guards it once it is reachable from
/// other machines.
///
/// A token is given as `env:NAME` or `file:<path>`, never as the value
/// itself: arguments show in `ps` to every user of the machine.
enum RemoteAccess {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 7878

    struct ServeOptions: Equatable {
        var host: String
        var port: Int
        /// Nil only on loopback without `--token`, today's open local server.
        var token: String?
        /// Where the token came from, to print: a file path or `$NAME`.
        var tokenSource: String?
    }

    /// `serve [--host <addr>] [--port <n>] [--token env:NAME|file:<path>]`.
    /// A non-loopback address without `--token` uses (creating it the first
    /// time) the token file in `stateDirectory`.
    static func serveOptions(
        arguments: [String],
        environment: [String: String],
        stateDirectory: URL
    ) throws -> ServeOptions {
        let flags = try flagValues(arguments, allowed: ["--host", "--port", "--token"], command: "serve")
        let host = flags["--host"] ?? defaultHost
        guard !host.isEmpty else { throw UsageError("serve --host needs an address") }

        var port = defaultPort
        if let text = flags["--port"] {
            guard let parsed = Int(text), (0...65535).contains(parsed) else {
                throw UsageError("serve --port \(text) is not a port number (0–65535)")
            }
            port = parsed
        }

        if let tokenArgument = flags["--token"] {
            let token = try readToken(tokenArgument, flag: "serve --token", environment: environment)
            return ServeOptions(host: host, port: port, token: token, tokenSource: tokenSourceName(tokenArgument))
        }
        guard !isLoopback(host) else {
            return ServeOptions(host: host, port: port, token: nil, tokenSource: nil)
        }
        let tokenFile = stateDirectory.appendingPathComponent("serve-token")
        let token = try generatedToken(at: tokenFile)
        return ServeOptions(host: host, port: port, token: token, tokenSource: tokenFile.path)
    }

    /// `connect <url> [--token env:NAME|file:<path>]`. Without `--token`,
    /// `NAWA_SERVE_TOKEN` if set, else none.
    static func connectBridge(arguments: [String], environment: [String: String]) throws -> ACPRemoteBridge {
        let usage = "usage: nawa connect <ws|wss|http|https URL> [--token env:NAME|file:<path>]"
        guard let address = arguments.first, !address.hasPrefix("--") else { throw UsageError(usage) }
        let flags = try flagValues(Array(arguments.dropFirst()), allowed: ["--token"], command: "connect")

        var token = environment["NAWA_SERVE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        if let tokenArgument = flags["--token"] {
            token = try readToken(tokenArgument, flag: "connect --token", environment: environment)
        }
        guard let bridge = ACPRemoteBridge(address: address, token: token) else {
            throw UsageError("\(address) is not a ws://, wss://, http:// or https:// URL\n" + usage)
        }
        return bridge
    }

    /// What `serve` says on stderr when it can be reached from elsewhere.
    static func warning(for options: ServeOptions) -> String? {
        guard !isLoopback(options.host) else { return nil }
        return "nawa: listening on \(options.host) without TLS: the token and everything the agent does cross the network unencrypted unless a TLS proxy (Caddy, nginx, a tunnel) is in front"
    }

    /// `127.0.0.1:7878`, `[::1]:7878`.
    static func authority(host: String, port: Int) -> String {
        let isIPv6Address = host.contains(":")
        return isIPv6Address ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        return name == "localhost" || name == "::1" || name == "[::1]" || name.hasPrefix("127.")
    }

    // MARK: Arguments

    /// `--name value` pairs. Every flag here takes a value.
    private static func flagValues(_ arguments: [String], allowed: Set<String>, command: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard allowed.contains(flag) else {
                throw UsageError("\(command): unknown argument \(flag)\n" + AgentCLI.usage)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { throw UsageError("\(command) \(flag) needs a value") }
            values[flag] = arguments[valueIndex]
            index += 2
        }
        return values
    }

    // MARK: Tokens

    /// The token `env:NAME` or `file:<path>` names.
    static func readToken(_ argument: String, flag: String, environment: [String: String]) throws -> String {
        if argument.hasPrefix("env:") {
            let name = String(argument.dropFirst("env:".count))
            guard let value = environment[name], !value.isEmpty else {
                throw UsageError("\(flag) \(argument): $\(name) is not set")
            }
            return value
        }
        if argument.hasPrefix("file:") {
            let path = String(argument.dropFirst("file:".count))
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw UsageError("\(flag) \(argument): can't read \(path)")
            }
            let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw UsageError("\(flag) \(argument): \(path) is empty") }
            return token
        }
        throw UsageError("\(flag) takes env:NAME or file:<path>, not the token itself: command lines show in ps to every user of the machine")
    }

    private static func tokenSourceName(_ argument: String) -> String {
        argument.hasPrefix("env:") ? "$" + argument.dropFirst("env:".count) : String(argument.dropFirst("file:".count))
    }

    /// The token in `file`, created with a new random one the first time.
    /// An existing file is used only if it is ours and private: anyone who
    /// could read or replace it could use the agent.
    static func generatedToken(at file: URL) throws -> String {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            let token = randomToken()
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data((token + "\n").utf8))
            try handle.close()
            return token
        }
        guard errno == EEXIST else {
            throw TokenFileError("can't create \(file.path): \(String(cString: strerror(errno)))")
        }

        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            throw TokenFileError("can't read \(file.path): \(String(cString: strerror(errno)))")
        }
        let isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
        let isOurs = info.st_uid == getuid()
        let isPrivate = (info.st_mode & 0o777) == 0o600
        guard isRegularFile, isOurs, isPrivate else {
            throw TokenFileError("\(file.path) must be a regular file owned by you with mode 600 (chmod 600 it, or remove it for a new token)")
        }
        let token = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw TokenFileError("\(file.path) holds no token (remove it for a new one)")
        }
        return token
    }

    /// 32 random bytes as hex. `SystemRandomNumberGenerator` is the
    /// system's cryptographic source on macOS and Linux.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct TokenFileError: Error, LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
