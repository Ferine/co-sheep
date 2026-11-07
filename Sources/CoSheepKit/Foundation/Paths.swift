import Foundation

/// Root of all persisted state: `~/.co-sheep/`, or `$CO_SHEEP_HOME` for dev
/// runs against a scratch copy. Tests point `root` at a temp dir (suites that
/// do must be `.serialized` and restore it).
enum Paths {
    static var root: URL = {
        if let dir = ProcessInfo.processInfo.environment["CO_SHEEP_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".co-sheep", isDirectory: true)
    }()

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    static func dir(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    static var config: URL { file("config.json") }
    static var opinions: URL { file("opinions.json") }
    static var journal: URL { dir("journal") }
    static var friends: URL { dir("friends") }
}
