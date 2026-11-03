import Foundation

/// Resolves a tool's path argument: absolute paths as given, `~` and `~/…`
/// under the home directory, relative ones against the session's working
/// directory.
///
/// Models write `~/notes.md` the way a person would; taken literally it
/// would create a folder named `~` inside the working directory.
func resolvedPath(_ path: String, in root: URL) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return root.appendingPathComponent(path)
}

/// The first executable `name` in `searchPath` (a `PATH`-style list), or nil.
func findExecutable(named name: String, searchPath: String?) -> URL? {
    let folders = (searchPath ?? "").split(separator: ":").map(String.init)
    for folder in folders where !folder.isEmpty {
        let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}
