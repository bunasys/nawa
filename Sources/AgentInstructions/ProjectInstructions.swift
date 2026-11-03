import Foundation

/// The instructions a project gives to agents, loaded from `AGENTS.md`.
///
/// A directory without an `AGENTS.md` may have a `CLAUDE.md` instead: many
/// projects only have the one Claude Code reads, and it holds the same kind
/// of guidance. A directory with both uses its `AGENTS.md`.
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
    /// The AGENTS.md files from the project root down to `nearest`, ordered
    /// from root-most to nearest (so concatenation reads top-down).
    public var files: [URL]
    /// The raw concatenated markdown (root first, nearest last).
    public var text: String

    /// The instructions from `files`. Never nil: the optional is kept so
    /// existing callers still compile; `load` returns nil when there are
    /// no files.
    public init?(nearest: URL, files: [URL], text: String) {
        self.nearest = nearest
        self.files = files
        self.text = text
    }

    /// A file bigger than this is not instructions anyone wrote by hand,
    /// and it would be resent with every request; it is skipped. The same
    /// cap as a SKILL.md.
    static let maxFileBytes = SkillCatalog.maxSkillFileBytes

    /// Load the instructions chain for the given start directory.
    ///
    /// Searches `start` and its parents up to the git root (outside a git
    /// repository, `start` alone) for `AGENTS.md` (or, where there is
    /// none, `CLAUDE.md`). Results are ordered root-most first, nearest
    /// last, so that a nested AGENTS.md takes precedence over its parents'
    /// instructions (the standard's "nearest wins").
    ///
    /// A file that isn't a regular file, is too big, or isn't UTF-8 text
    /// is skipped; the rest of the chain still loads. It never throws: the
    /// signature is kept for existing callers.
    public static func load(from start: URL) throws -> ProjectInstructions? {
        var files: [URL] = []
        var texts: [String] = []
        // projectDirectories is nearest first; the chain reads root first.
        for directory in projectDirectories(from: URL(fileURLWithPath: start.path)).reversed() {
            let agentsMD = directory.appendingPathComponent("AGENTS.md")
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            // A directory with an AGENTS.md uses it, even when it can't be read.
            let file = FileManager.default.fileExists(atPath: agentsMD.path) ? agentsMD : claudeMD
            guard let text = readTextFile(file, maxBytes: maxFileBytes) else { continue }
            files.append(file)
            texts.append(text)
        }
        guard let nearest = files.last else { return nil }
        return ProjectInstructions(nearest: nearest, files: files, text: texts.joined(separator: "\n\n"))
    }

    /// Convenience: load instructions for the current working directory.
    public static func loadForCurrentWorkingDirectory() throws -> ProjectInstructions? {
        try load(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Whether a given file is governed by these instructions (it lives at or
    /// below the directory that owns the nearest AGENTS.md).
    public func governs(_ url: URL) -> Bool {
        // Compared by path component: a prefix of the path string would let
        // `/a/b` govern `/a/bc`.
        let owner = nearest.deletingLastPathComponent().standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.starts(with: owner)
    }
}
