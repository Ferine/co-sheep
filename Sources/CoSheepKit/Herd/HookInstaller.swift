import Foundation

// Agent herd: installs the Claude Code command hooks that report sessions to
// co-sheep. Spec: docs/superpowers/specs/2026-10-03-agent-herd-design.md
// ("Installer").
//
// Two files are involved: the shim (`~/.co-sheep/hooks/claude-hook.sh`, ours)
// and `~/.claude/settings.json` (another tool's: every byte we don't own is
// preserved, a file that doesn't parse is never overwritten, and every write
// is preceded by a backup).

nonisolated enum HookInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// The settings reference our shim, but something is off (the reason is
    /// user-facing): shim missing or not executable, port/token out of sync
    /// with the config, or events missing. "Repair" fixes all of it.
    case stale(String)
}

nonisolated enum HookInstallError: Error, LocalizedError, Equatable {
    /// `settings.json` exists but isn't a JSON object. Never overwritten.
    case settingsNotJSON
    /// `settings.json` parses, but a part we need to edit has the wrong type.
    case unexpectedLayout(String)
    /// The bearer token can't be carried in an HTTP header.
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .settingsNotJSON:
            "settings.json isn't valid JSON, so co-sheep won't touch it."
        case .unexpectedLayout(let what):
            "settings.json has an unexpected layout (\(what) isn't what Claude Code writes), so co-sheep won't touch it."
        case .invalidToken:
            "The MCP token in co-sheep's config contains characters that can't go in an HTTP header."
        }
    }
}

struct HookInstaller {
    /// Every event we register.
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PermissionDenied", "PostToolUse", "PostToolUseFailure", "Notification", "Stop",
        "StopFailure", "SubagentStart", "SubagentStop", "PreCompact",
    ]
    /// Events whose hook runs synchronously (`timeout: 2`, no `async`).
    /// SessionEnd hooks share a ~1.5 s budget at teardown, and async at
    /// teardown is undocumented. All others are async: zero latency for the agent.
    static let synchronousEvents: Set<String> = ["SessionEnd"]
    static let asyncTimeoutSecs = 5
    static let syncTimeoutSecs = 2
    static let maxBackups = 3
    static let backupPrefix = "settings.json.co-sheep-backup-"
    /// Any command ending like this is ours, whichever home it was installed from.
    static let shimSuffix = "/.co-sheep/hooks/claude-hook.sh"

    var claudeDir: URL
    var shimURL: URL
    var port: UInt16
    var token: String

    /// `$CO_SHEEP_CLAUDE_DIR` (dev/tests) or `~/.claude`.
    static var defaultClaudeDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CO_SHEEP_CLAUDE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// `<Paths.root>/hooks/claude-hook.sh`.
    static var defaultShimURL: URL {
        Paths.dir("hooks").appendingPathComponent("claude-hook.sh")
    }

    init(
        claudeDir: URL = HookInstaller.defaultClaudeDir,
        shimURL: URL = HookInstaller.defaultShimURL,
        port: UInt16 = 4917,
        token: String = ""
    ) {
        self.claudeDir = claudeDir
        self.shimURL = shimURL
        self.port = port
        self.token = token
    }

    /// Port and token come from the config (`mcp_port`, `mcp_token`).
    init(
        config: SheepConfig,
        claudeDir: URL = HookInstaller.defaultClaudeDir,
        shimURL: URL = HookInstaller.defaultShimURL
    ) {
        self.init(claudeDir: claudeDir, shimURL: shimURL, port: config.mcpPort, token: config.mcpToken)
    }

    var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    /// What goes in a hook's `command`: the shim path, single-quoted only if
    /// it contains anything a shell would treat specially.
    var shimCommand: String { Self.shellWord(shimURL.path) }

    // MARK: Shim

    /// Tokens travel in an `Authorization` header: printable ASCII only.
    static func isValidToken(_ token: String) -> Bool {
        token.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }

    /// POSIX single-quoting: safe for any string.
    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellWord(_ s: String) -> String {
        let safe = !s.isEmpty && s.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
                || "_@%+=:,./-".utf8.contains(b)
        }
        return safe ? s : singleQuoted(s)
    }

    private static func authorizationLine(token: String) -> String? {
        token.isEmpty ? nil : "  -H \(singleQuoted("Authorization: Bearer \(token)")) \\"
    }

    /// The shim. Reads the hook JSON from stdin *first* (a backgrounded job
    /// would get /dev/null), then POSTs it to the loopback server. Prints
    /// nothing and always exits 0: a hook that exits 2 blocks the agent, any
    /// other non-zero exit shows a "hook error", and stdout from some events
    /// is injected into the model's context.
    static func shimScript(port: UInt16, token: String) -> String {
        var lines = [
            "#!/bin/sh",
            "# co-sheep: Claude Code hook (written by co-sheep; Connect/Repair rewrites it).",
            "# Forwards the hook event on stdin to co-sheep on 127.0.0.1:\(port) so the session",
            "# shows up as a lamb on the desktop. Prints nothing and ALWAYS exits 0, so it can",
            "# never block, steer or slow down Claude Code.",
            "payload=$(cat)",
            "pid=${CLAUDE_PID:-$PPID}",
            "case $pid in ''|*[!0-9]*) pid=$PPID ;; esac",
            "{ printf '%s' \"$payload\" | /usr/bin/curl -s -o /dev/null --connect-timeout 0.3 -m 1 \\",
            "  --noproxy '*' -X POST -H 'Content-Type: application/json' -H 'Expect:' \\",
            "  -H \"X-Co-Sheep-Pid: $pid\" \\",
        ]
        if let auth = authorizationLine(token: token) { lines.append(auth) }
        lines.append("  --data-binary @- \"http://127.0.0.1:\(port)/hook\" ; } >/dev/null 2>&1")
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    var script: String { Self.shimScript(port: port, token: token) }

    // MARK: Install / uninstall

    /// Writes the shim and merges one matcher group per event into
    /// `settings.json`. Idempotent. Throws, touching nothing, when the
    /// settings can't be safely edited.
    func install(now: Date = Date()) throws {
        guard Self.isValidToken(token) else { throw HookInstallError.invalidToken }
        // Parse and merge before writing anything, so a refusal leaves no trace.
        let existing = try readSettings()
        let merged = try mergingOurs(into: existing ?? [:])
        try writeShim()
        try writeSettings(merged, now: now)
        Log.info("herd", "Claude Code hooks installed (\(shimURL.path))")
    }

    /// Removes only our hooks (and containers that become empty), then the
    /// shim. Throws, touching nothing, when the settings can't be safely edited.
    func uninstall(now: Date = Date()) throws {
        if let existing = try readSettings() {
            let (stripped, changed) = try removingOurs(from: existing)
            if changed { try writeSettings(stripped, now: now) }
        }
        if FileManager.default.fileExists(atPath: shimURL.path) {
            try FileManager.default.removeItem(at: shimURL)
        }
        Log.info("herd", "Claude Code hooks removed")
    }

    func status() -> HookInstallStatus {
        guard let settings = try? readSettings(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return .notInstalled }

        let referencesUs = hooks.values.contains { value in
            Self.entries(in: value).contains { isOurs($0) }
        }
        guard referencesUs else { return .notInstalled }

        let fm = FileManager.default
        if !fm.fileExists(atPath: shimURL.path) {
            return .stale("the hook script is missing")
        }
        if !fm.isExecutableFile(atPath: shimURL.path) {
            return .stale("the hook script isn't executable")
        }
        if let text = try? String(contentsOf: shimURL, encoding: .utf8), text != script {
            if let baked = Self.bakedPort(in: text), baked != port {
                return .stale("the hook script posts to a different port than co-sheep listens on")
            }
            let auth = Self.authorizationLine(token: token)
            if auth.map({ !text.contains($0) }) ?? text.contains("Authorization: Bearer") {
                return .stale("the hook script has an out-of-date token")
            }
            return .stale("the hook script is out of date")
        }
        let missing = Self.events.filter { event in
            !Self.entries(in: hooks[event]).contains { isCurrent($0, for: event) }
        }
        if !missing.isEmpty {
            return .stale("missing hooks for \(missing.joined(separator: ", "))")
        }
        return .installed
    }

    private static func bakedPort(in script: String) -> UInt16? {
        guard let r = script.range(of: "http://127.0.0.1:") else { return nil }
        return UInt16(script[r.upperBound...].prefix { $0.isNumber })
    }

    // MARK: Settings JSON

    /// nil when the file doesn't exist; throws when it isn't a JSON object.
    private func readSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.settingsNotJSON
        }
        return object
    }

    private func hooksDictionary(of root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw HookInstallError.unexpectedLayout("\"hooks\"") }
        return hooks
    }

    /// The hook entries of one event's value (an array of matcher groups).
    private static func entries(in eventValue: Any?) -> [[String: Any]] {
        guard let groups = eventValue as? [Any] else { return [] }
        return groups.flatMap { group -> [[String: Any]] in
            ((group as? [String: Any])?["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
    }

    /// A command hook that runs our shim (from any home, quoted or not).
    private func isOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        let bare = command.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return bare == shimURL.path || bare.hasSuffix(Self.shimSuffix)
    }

    private func ourEntry(for event: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": shimCommand]
        if Self.synchronousEvents.contains(event) {
            entry["timeout"] = Self.syncTimeoutSecs
        } else {
            entry["timeout"] = Self.asyncTimeoutSecs
            entry["async"] = true
        }
        return entry
    }

    /// Our hook as we'd write it today (right command, right sync/async mode).
    private func isCurrent(_ entry: [String: Any], for event: String) -> Bool {
        guard entry["command"] as? String == shimCommand else { return false }
        let isAsync = (entry["async"] as? Bool) == true
        return isAsync == !Self.synchronousEvents.contains(event)
    }

    /// `groups` without our hook entries. A group that held only ours goes
    /// away; a group that mixed ours with someone else's keeps theirs.
    private func strippingOurs(from groups: [Any]) -> (groups: [Any], removed: Bool) {
        var kept: [Any] = []
        var removed = false
        for raw in groups {
            guard var group = raw as? [String: Any], let hooks = group["hooks"] as? [Any] else {
                kept.append(raw)
                continue
            }
            let remaining = hooks.filter { ($0 as? [String: Any]).map { !isOurs($0) } ?? true }
            if remaining.count == hooks.count {
                kept.append(raw)
                continue
            }
            removed = true
            if remaining.isEmpty { continue }
            group["hooks"] = remaining
            kept.append(group)
        }
        return (kept, removed)
    }

    private func mergingOurs(into root: [String: Any]) throws -> [String: Any] {
        var hooks = try hooksDictionary(of: root)
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                if Self.events.contains(event) { throw HookInstallError.unexpectedLayout("\"hooks.\(event)\"") }
                continue
            }
            let (stripped, removed) = strippingOurs(from: groups)
            if removed { hooks[event] = stripped.isEmpty ? nil : stripped }
        }
        for event in Self.events {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(["matcher": "*", "hooks": [ourEntry(for: event)]] as [String: Any])
            hooks[event] = groups
        }
        var merged = root
        merged["hooks"] = hooks
        return merged
    }

    private func removingOurs(from root: [String: Any]) throws -> (root: [String: Any], changed: Bool) {
        var hooks = try hooksDictionary(of: root)
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let (stripped, removed) = strippingOurs(from: groups)
            guard removed else { continue }
            changed = true
            hooks[event] = stripped.isEmpty ? nil : stripped
        }
        guard changed else { return (root, false) }
        var result = root
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return (result, true)
    }

    // MARK: Files

    private func writeShim() throws {
        try FileManager.default.createDirectory(
            at: shimURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Self.atomicWrite(Data(script.utf8), to: shimURL, permissions: 0o700)
    }

    /// Backs up the current file (if any), then replaces it. A write that
    /// wouldn't change a byte is skipped, so repeated Connects can't push the
    /// user's original out of the 3 kept backups. A symlinked settings.json
    /// (dotfile managers) is written through, and its permissions are kept.
    private func writeSettings(_ root: [String: Any], now: Date) throws {
        var data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)

        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try Self.atomicWrite(data, to: settingsURL, permissions: 0o600)
            return
        }
        let target = settingsURL.resolvingSymlinksInPath()
        if (try? Data(contentsOf: target)) == data { return }
        let permissions = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0o600
        try backUpSettings(now: now)
        try Self.atomicWrite(data, to: target, permissions: permissions)
        pruneBackups()
    }

    private func backUpSettings(now: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let fm = FileManager.default
        var backup = claudeDir.appendingPathComponent(Self.backupPrefix + stamp)
        var n = 1
        while fm.fileExists(atPath: backup.path) {
            n += 1
            backup = claudeDir.appendingPathComponent("\(Self.backupPrefix)\(stamp)-\(n)")
        }
        try fm.copyItem(at: settingsURL.resolvingSymlinksInPath(), to: backup)
    }

    /// Keeps the `maxBackups` newest backups (by timestamp, then counter).
    private func pruneBackups() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: claudeDir.path)) ?? []
        let ranked = names.compactMap { name -> (name: String, stamp: String, n: Int)? in
            guard name.hasPrefix(Self.backupPrefix) else { return nil }
            let parts = name.dropFirst(Self.backupPrefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            return (name, "\(parts[0])-\(parts[1])", parts.count > 2 ? Int(parts[2]) ?? 1 : 1)
        }.sorted { ($0.stamp, $0.n) < ($1.stamp, $1.n) }
        for old in ranked.dropLast(Self.maxBackups) {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(old.name))
        }
    }

    /// Temp file (created with `permissions`, so there's no window where it's
    /// more readable than the target) + atomic rename.
    private static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).co-sheep-tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            // The umask may have narrowed the mode; make it exact.
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
            guard rename(tmp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
