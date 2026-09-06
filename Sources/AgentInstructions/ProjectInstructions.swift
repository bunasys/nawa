import Foundation

/// The instructions a project gives to agents, loaded from `AGENTS.md`.
///
/// Implements the https://agents.md/ standard:
/// - One markdown file per directory level, named `AGENTS.md`.
/// - Agents read the *nearest* `AGENTS.md` to the file they are working on;
///   nested files take precedence over parent ones. Combined chains are ordered
///   root-most first, nearest last — the closest file therefore has the last
///   (highest-precedence) word.
/// - There are no required fields — the whole file is free-form markdown text.
/// - Explicit user chat prompts override everything (enforced by the prompt
///   builder, which always places the user's message after instructions).
public struct ProjectInstructions: Sendable, Hashable {
    /// The nearest AGENTS.md (highest precedence), if found.
    public var nearest: URL
    /// All AGENTS.md files from the filesystem root down to `nearest`, ordered
    /// from root-most to nearest (so concatenation reads top-down).
    public var files: [URL]
    /// The raw concatenated markdown (root first, nearest last).
    public var text: String

    /// The instructions loaded for a directory, or nil if no AGENTS.md exists.
    public init?(nearest: URL, files: [URL], text: String) {
        self.nearest = nearest
        self.files = files
        self.text = text
    }

    /// Load the instructions chain for the given start directory.
    ///
    /// Searches `start` and every parent directory for `AGENTS.md`. Results are
    /// ordered root-most first, nearest last, so that a nested AGENTS.md takes
    /// precedence over its parents' instructions (the standard's "nearest wins").
    public static func load(from start: URL) throws -> ProjectInstructions? {
        var directory = URL(fileURLWithPath: start.path).standardizedFileURL
        var files: [URL] = []
        while true {
            let candidate = directory.appendingPathComponent("AGENTS.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                files.append(candidate)
            }
            guard directory.path != "/" else { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        // We collected nearest-first while walking up; reverse for root-first.
        let ordered = Array(files.reversed())
        guard let nearest = ordered.last else { return nil }
        let text = try ordered.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
        return ProjectInstructions(nearest: nearest, files: ordered, text: text)
    }

    /// Convenience: load instructions for the current working directory.
    public static func loadForCurrentWorkingDirectory() throws -> ProjectInstructions? {
        try load(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Whether a given file is governed by these instructions (it lives at or
    /// below the directory that owns the nearest AGENTS.md).
    public func governs(_ url: URL) -> Bool {
        let owner = nearest.deletingLastPathComponent().path
        return url.path.hasPrefix(owner) || url.path.hasSuffix("/" + (nearest.lastPathComponent))
    }
}
