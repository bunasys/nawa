import AgentCore
import Foundation

/// Visits files the way ripgrep does, for machines without ripgrep, so
/// `search` and `list_files` give the same answers either way:
///
/// - hidden files and directories (`.name`) are skipped, symlinks are not followed;
/// - `.gitignore` applies inside a git repository, `.ignore` and `.rgignore`
///   anywhere, plus `.git/info/exclude`; ignore files in parent directories
///   up to the repository root count too, and deeper files win;
/// - entries are visited depth-first, sorted by name within each directory
///   (ripgrep's `--sort=path`);
/// - binary files (containing a NUL byte) are not searched.
///
/// Not covered: the user's global git excludes file (`core.excludesFile`).
struct FileWalk {
    let workingDirectory: URL

    struct File {
        /// The path as ripgrep prints it: the requested path plus the rest.
        var display: String
        var url: URL
    }

    /// Files under `path` (or `path` itself, if it is a file), filtered by a
    /// gitignore-style `glob`; a glob starting with `!` excludes instead.
    func files(under path: String, glob: String?) throws -> [File] {
        let root = resolvedPath(path, in: workingDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ToolError.runtimeError("\(path): no such file or directory")
        }
        guard isDirectory.boolValue else { return [File(display: path, url: root)] }

        var found: [File] = []
        let filter = glob.flatMap(IgnorePattern.init)
        walk(root, display: path, rules: IgnoreRules.inherited(by: root), filter: filter, into: &found)
        return found
    }

    /// Lines matching `pattern` as `path:line:text`.
    func search(pattern: String, under path: String, glob: String?) throws -> [String] {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ToolError.argumentError("invalid regular expression: \(pattern)")
        }
        var matches: [String] = []
        for file in try files(under: path, glob: glob) {
            guard let data = try? Data(contentsOf: file.url), !data.contains(0) else { continue }
            var lineNumber = 0
            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                lineNumber += 1
                let wholeLine = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, range: wholeLine) != nil else { return }
                let shown = line.count > CapturedOutput.maxLineLength
                    ? String(line.prefix(CapturedOutput.maxLineLength)) + " […]"
                    : line
                matches.append("\(file.display):\(lineNumber):\(shown)")
            }
        }
        return matches
    }

    private func walk(_ directory: URL, display: String, rules inherited: IgnoreRules, filter: IgnorePattern?, into found: inout [File]) {
        let rules = inherited.adding(ignoreFilesIn: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true
            if rules.ignores(url.path, isDirectory: isDirectory) { continue }

            let childDisplay = display.hasSuffix("/") ? display + name : display + "/" + name
            if isDirectory {
                walk(url, display: childDisplay, rules: rules, filter: filter, into: &found)
            } else if passes(filter, url) {
                found.append(File(display: childDisplay, url: url))
            }
        }
    }

    /// ripgrep matches `--glob` against the path relative to the directory it
    /// runs in; outside that directory, the full path is the closest equivalent.
    private func passes(_ filter: IgnorePattern?, _ url: URL) -> Bool {
        guard let filter else { return true }
        let base = workingDirectory.standardizedFileURL.path + "/"
        let relative = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
        let matches = filter.matches(relative, isDirectory: false)
        return filter.negated ? !matches : matches
    }
}

/// The ignore rules in force at some directory: every pattern from the ignore
/// files above it, outermost first, each with the directory it is relative to.
struct IgnoreRules {
    /// `.gitignore` only counts inside a git repository, as in ripgrep.
    var insideGitRepository: Bool
    var rules: [(base: String, pattern: IgnorePattern)] = []

    /// Rules a walk starting at `root` inherits: `.git/info/exclude` and the
    /// ignore files of `root`'s parents up to the repository root.
    static func inherited(by root: URL) -> IgnoreRules {
        // Listed from the path's components so the walk up always ends at
        // "/". Asking a URL for its parent until the path stops changing
        // never ended for temp-directory URLs and grew memory without bound.
        let components = root.standardizedFileURL.pathComponents
        let rootAndAncestors = (1...components.count).reversed().map { depth in
            URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(depth))))
        }
        let gitRootIndex = rootAndAncestors.firstIndex { directory in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
        }
        guard let gitRootIndex else { return IgnoreRules(insideGitRepository: false) }
        let gitRoot = rootAndAncestors[gitRootIndex]
        // The walk loads `root`'s own ignore files itself, so start one above it.
        let parents = rootAndAncestors[..<(gitRootIndex + 1)].dropFirst()

        var rules = IgnoreRules(insideGitRepository: true)
        rules.load(gitRoot.appendingPathComponent(".git/info/exclude"), base: gitRoot)
        for parent in parents.reversed() {
            rules = rules.adding(ignoreFilesIn: parent)
        }
        return rules
    }

    /// These rules plus those in `directory`'s own ignore files. Later files
    /// take precedence, matching ripgrep: `.rgignore` over `.ignore` over `.gitignore`.
    func adding(ignoreFilesIn directory: URL) -> IgnoreRules {
        var extended = self
        if insideGitRepository {
            extended.load(directory.appendingPathComponent(".gitignore"), base: directory)
        }
        extended.load(directory.appendingPathComponent(".ignore"), base: directory)
        extended.load(directory.appendingPathComponent(".rgignore"), base: directory)
        return extended
    }

    /// The last matching pattern decides; a `!pattern` re-includes.
    func ignores(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules {
            let base = rule.base.hasSuffix("/") ? rule.base : rule.base + "/"
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            if rule.pattern.matches(relative, isDirectory: isDirectory) {
                ignored = !rule.pattern.negated
            }
        }
        return ignored
    }

    private mutating func load(_ file: URL, base: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let basePath = base.standardizedFileURL.path
        for line in text.components(separatedBy: .newlines) {
            if let pattern = IgnorePattern(line) {
                rules.append((basePath, pattern))
            }
        }
    }
}

/// One line of a gitignore file, compiled to a regular expression over a
/// `/`-separated path relative to the file's directory.
struct IgnorePattern {
    var negated: Bool
    /// A trailing `/` makes a pattern match directories only.
    var directoryOnly: Bool
    var regex: NSRegularExpression

    /// Nil for blank lines and comments.
    init?(_ line: String) {
        var pattern = line
        while pattern.hasSuffix(" ") && !pattern.hasSuffix("\\ ") {
            pattern.removeLast()
        }
        if pattern.isEmpty || pattern.hasPrefix("#") { return nil }

        negated = pattern.hasPrefix("!")
        if negated { pattern.removeFirst() }
        directoryOnly = pattern.hasSuffix("/")
        if directoryOnly { pattern.removeLast() }

        // A slash at the start or in the middle ties the pattern to the
        // ignore file's directory; without one it matches at any depth.
        let isAnchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if !isAnchored { pattern = "**/" + pattern }

        guard let regex = try? NSRegularExpression(pattern: "^" + Self.regexSource(glob: pattern) + "$") else {
            return nil
        }
        self.regex = regex
    }

    func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        let wholePath = NSRange(relativePath.startIndex..., in: relativePath)
        return regex.firstMatch(in: relativePath, range: wholePath) != nil
    }

    /// `*` and `?` stay within one path segment; `**` spans segments when it
    /// is a whole segment (`**/x`, `x/**`, `x/**/y`); `[...]` is a character
    /// class, `[!...]` a negated one; `\` escapes the next character.
    static func regexSource(glob: String) -> String {
        let characters = Array(glob)
        var source = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "*" && next == "*" {
                let startsSegment = index == 0 || characters[index - 1] == "/"
                let afterStars = index + 2 < characters.count ? characters[index + 2] : nil
                if startsSegment && afterStars == "/" {
                    source += "(?:.*/)?"
                    index += 3
                    continue
                }
                if startsSegment && afterStars == nil {
                    source += ".*"
                    index += 2
                    continue
                }
                source += "[^/]*"
                index += 2
                continue
            }

            switch character {
            case "*":
                source += "[^/]*"
            case "?":
                source += "[^/]"
            case "\\" where next != nil:
                source += NSRegularExpression.escapedPattern(for: String(next!))
                index += 1
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var members = String(characters[(index + 1)..<close])
                    if members.hasPrefix("!") { members = "^" + members.dropFirst() }
                    source += "[" + members.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close
                } else {
                    source += "\\["
                }
            default:
                source += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return source
    }
}
