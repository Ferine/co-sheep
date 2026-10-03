import Foundation

/// Which repo a session works in: the nearest ancestor of its cwd with a `.git`
/// entry. Lambs on the same repo share a wool colour (hashed from `key`) and a
/// name tag (`name`).
nonisolated enum RepoIdentity {
    static let maxLevels = 40

    /// Walks up from `cwd` (at most `maxLevels` directories) looking for `.git`.
    /// A worktree's `.git` is a file, a normal checkout's a directory; either
    /// counts. Not in a repo: the cwd itself is the key.
    static func resolve(
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (key: String, name: String) {
        let start = normalized(cwd)
        var dir = start
        for _ in 0..<maxLevels {
            if fileExists(join(dir, ".git")) { return (dir, lastComponent(dir)) }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir { break }
            dir = parent
        }
        return (start, lastComponent(start))
    }

    /// Trailing slashes dropped (except for the root), so `/a/b/` and `/a/b` are one key.
    private static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    private static func lastComponent(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}
