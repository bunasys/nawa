import AgentCore
import Foundation

/// A skill: a folder of instructions, scripts and references for one kind
/// of task (querying a system's logs, a team's release steps, …), in the
/// agentskills.io layout: `<name>/SKILL.md`, whose frontmatter has a
/// `name` and a `description`.
///
/// The model sees each skill's name and description in the system prompt
/// and reads its `SKILL.md` with `read_file` when a task matches. Loading
/// the body only on demand keeps the per-request cost to one line a skill.
public struct Skill: Sendable, Hashable {
    /// The skill's folder name: what the list shows and what decides which
    /// of two same-named skills wins.
    public var name: String
    /// From the frontmatter, whitespace collapsed; empty when missing.
    public var description: String
    /// The skills folder it was found in (e.g. `<project>/.claude/skills`).
    public var root: URL

    public var directory: URL { root.appendingPathComponent(name) }
    public var file: URL { directory.appendingPathComponent("SKILL.md") }

    public init(name: String, description: String, root: URL) {
        self.name = name
        self.description = description
        self.root = root
    }
}

/// The skills available in a session, and the list of them for the system
/// prompt.
public struct SkillCatalog: Sendable {
    /// Nearest first: project skills before the user's.
    public var skills: [Skill]

    /// The list's size limit in characters (~2.5K tokens). It is sent with
    /// every request, so it gets a fixed budget however many skills exist.
    public static let indexBudget = 10_000
    /// Descriptions are shortened through these lengths until the list fits;
    /// nil keeps them whole. The small steps matter: a short description
    /// still tells the model what a skill is for, a bare name often doesn't.
    static let descriptionLengths: [Int?] = [nil, 250, 120, 80, 60, 40, 0]
    static let maxDescriptionLength = 1_024
    /// A SKILL.md bigger than this is not a skill anyone wrote by hand; skip it.
    static let maxSkillFileBytes = 256 * 1024

    public init(skills: [Skill]) {
        self.skills = skills
    }

    // MARK: Finding skills

    /// The skills for a session in `directory`: the project's (from the
    /// directory up to its git root) and then the user's. Without
    /// `includeProjectSkills`, only the user's, for repositories you don't
    /// trust. `environment` gives `HOME` and `XDG_CONFIG_HOME`.
    public static func discover(from directory: URL, environment: [String: String], includeProjectSkills: Bool = true) -> SkillCatalog {
        var roots: [URL] = []
        if includeProjectSkills {
            roots += projectSkillRoots(from: directory)
        }
        roots += userSkillRoots(environment: environment)
        return load(roots: roots)
    }

    static let projectSkillFolders = [".agents/skills", ".claude/skills", ".nawa/skills"]

    static func projectSkillRoots(from directory: URL) -> [URL] {
        projectDirectories(from: directory).flatMap { folder in
            projectSkillFolders.map { folder.appendingPathComponent($0) }
        }
    }

    static func userSkillRoots(environment: [String: String]) -> [URL] {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        return [
            nawaConfigDirectory(environment: environment).appendingPathComponent("skills"),
            home.appendingPathComponent(".agents/skills"),
            home.appendingPathComponent(".claude/skills"),
        ]
    }

    /// Reads every skill in `roots`, in order. A name already taken by an
    /// earlier root is skipped, so earlier (nearer) roots win.
    public static func load(roots: [URL]) -> SkillCatalog {
        var skills: [Skill] = []
        var taken = Set<String>()
        var seenRoots = Set<String>()
        for root in roots {
            // A parent and its child can resolve to the same folder through a symlink.
            let resolvedRoot = root.resolvingSymlinksInPath().path
            guard !seenRoots.contains(resolvedRoot) else { continue }
            seenRoots.insert(resolvedRoot)

            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") && !taken.contains(name) {
                guard let skill = readSkill(named: name, in: root) else { continue }
                skills.append(skill)
                taken.insert(name)
            }
        }
        return SkillCatalog(skills: skills)
    }

    private static func readSkill(named name: String, in root: URL) -> Skill? {
        let file = root.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        // `attributesOfItem` doesn't follow symlinks, and shared skills are
        // usually symlinked folders, so ask for the size of the resolved file.
        let resolved = file.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attributes[.size] as? Int, size <= maxSkillFileBytes,
              let text = try? String(contentsOf: resolved, encoding: .utf8)
        else { return nil }

        let description = frontmatter(of: text)["description"] ?? ""
        return Skill(name: name, description: String(collapsingWhitespace(description).prefix(maxDescriptionLength)), root: root)
    }

    /// The `key: value` pairs between the leading `---` lines. Understands
    /// the YAML a SKILL.md uses: plain, quoted, and folded (`>` / `|`)
    /// values, and values continued on indented lines. Anything else
    /// (lists, nested maps) is kept as text, which is fine for a description.
    static func frontmatter(of text: String) -> [String: String] {
        // `\r\n` is one Character in Swift, so split on any newline, not on "\n".
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var fields: [String: String] = [:]
        var currentKey: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let isContinuation = line.first == " " || line.first == "\t"
            if isContinuation, let key = currentKey {
                fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let isBlockMarker = [">", "|", ">-", "|-", ">+", "|+"].contains(value)
            if isBlockMarker { value = "" }
            fields[key] = unquoted(value)
            currentKey = key
        }
        return fields.mapValues { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquoted(_ value: String) -> String {
        let isQuoted = value.count >= 2
            && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")))
        return isQuoted ? String(value.dropFirst().dropLast()) : value
    }

    // MARK: The list for the system prompt

    /// The list of skills for the system prompt, and whether descriptions
    /// had to be shortened to fit `indexBudget` (then `skill_search` is
    /// needed to see them whole). Roots under `workingDirectory` are shown
    /// relative to it, which `read_file` accepts and which costs fewer tokens.
    public func index(workingDirectory: URL) -> (text: String, isShortened: Bool) {
        var text = ""
        for length in Self.descriptionLengths {
            text = render(descriptionLength: length, workingDirectory: workingDirectory)
            if text.count <= Self.indexBudget { return (text, length != nil) }
        }
        // Even names alone don't fit: list as many as fit; skill_search finds the rest.
        let cut = text.prefix(Self.indexBudget)
        let lastWholeLine = cut.lastIndex(of: "\n") ?? cut.endIndex
        return (String(cut[..<lastWholeLine]) + "\n- … more: use skill_search", true)
    }

    private func render(descriptionLength: Int?, workingDirectory: URL) -> String {
        var sections: [String] = []
        var currentRoot: URL?
        var lines: [String] = []
        for skill in skills {
            if skill.root != currentRoot {
                if let currentRoot { sections.append(Self.header(for: currentRoot, workingDirectory) + "\n" + lines.joined(separator: "\n")) }
                currentRoot = skill.root
                lines = []
            }
            lines.append(Self.line(for: skill, descriptionLength: descriptionLength))
        }
        if let currentRoot { sections.append(Self.header(for: currentRoot, workingDirectory) + "\n" + lines.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }

    private static func header(for root: URL, _ workingDirectory: URL) -> String {
        "In \(displayPath(root, relativeTo: workingDirectory))/ (read <name>/SKILL.md there):"
    }

    private static func line(for skill: Skill, descriptionLength: Int?) -> String {
        let description = shortened(skill.description, to: descriptionLength)
        return description.isEmpty ? "- \(skill.name)" : "- \(skill.name): \(description)"
    }

    private static func shortened(_ text: String, to length: Int?) -> String {
        guard let length, text.count > length else { return text }
        if length == 0 { return "" }
        return String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Finds skills by keyword when the list in the system prompt had to be
/// shortened. Added only then, so sessions with a short list don't pay
/// for its definition.
public struct SkillSearchTool: Tool {
    public let skills: [Skill]
    static let maxResults = 8

    public init(skills: [Skill]) {
        self.skills = skills
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "skill_search",
            description: """
            Search the available skills by keyword (their names and full descriptions). \
            Returns the best matches with the path of each SKILL.md; read it with read_file \
            before using the skill.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("What the task is about, e.g. \"production logs\" or \"temporal workflow history\"."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        )
    }

    public func run(arguments: JSON) async throws -> String {
        guard let query = arguments.objectValue?["query"]?.stringValue else {
            throw ToolError.argumentError("missing string argument 'query'")
        }
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let scored = skills.compactMap { skill -> (Skill, Int)? in
            let name = skill.name.lowercased()
            let description = skill.description.lowercased()
            // A word in the name says more about the skill than one in its description.
            let score = words.reduce(0) { total, word in
                total + (name.contains(word) ? 3 : 0) + (description.contains(word) ? 1 : 0)
            }
            return score > 0 ? (skill, score) : nil
        }
        let best = scored.sorted { $0.1 > $1.1 }.prefix(Self.maxResults).map(\.0)
        if best.isEmpty { return "No skills match \"\(query)\"." }
        return best.map { skill in
            "\(skill.name) — \(skill.file.path)\n\(skill.description)"
        }.joined(separator: "\n\n")
    }
}

// MARK: Shared with SystemPrompt

/// `directory` and its parents up to the git root, nearest first. Outside a
/// git repository, just `directory`: walking up to `/` from a random folder
/// would pick up unrelated files.
func projectDirectories(from directory: URL) -> [URL] {
    let start = directory.standardizedFileURL
    var candidates: [URL] = []
    var current = start
    // The depth cap is a backstop: a walk that misses `/` must not run forever.
    for _ in 0..<256 {
        candidates.append(current)
        let gitMarker = current.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitMarker.path) { return candidates }
        // Checked by path, not by comparing with the parent: the parent of
        // `/` is `/..`, which never equals `/`.
        if current.path == "/" { break }
        current = current.deletingLastPathComponent().standardizedFileURL
    }
    return [start]
}

/// `$XDG_CONFIG_HOME/nawa`, else `~/.config/nawa`, as `nawa config` uses.
func nawaConfigDirectory(environment: [String: String]) -> URL {
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        return URL(fileURLWithPath: xdg).appendingPathComponent("nawa")
    }
    let home = environment["HOME"] ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent(".config/nawa")
}

func displayPath(_ url: URL, relativeTo workingDirectory: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = workingDirectory.standardizedFileURL.path
    if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    return path
}

func collapsingWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
