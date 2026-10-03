import Foundation
import Testing
@testable import CoSheepKit

// Agent herd: the Claude Code hook installer. Everything runs against temp
// directories (never the real ~/.claude or ~/.co-sheep): `withBrainRoot`
// points `Paths.root` at a temp dir and the installer is given a temp
// `claudeDir` explicitly.
extension BrainTests {
    @Suite("hook installer")
    struct HookInstallerTests {
        // MARK: helpers

        private func withInstaller<T>(
            port: UInt16 = 4917, token: String = "",
            _ body: (HookInstaller, URL) throws -> T
        ) throws -> T {
            try withBrainRoot { root in
                let installer = HookInstaller(
                    claudeDir: root.appendingPathComponent("claude", isDirectory: true),
                    shimURL: Paths.dir("hooks").appendingPathComponent("claude-hook.sh"),
                    port: port, token: token)
                return try body(installer, root)
            }
        }

        /// Same dirs as `base`, other port/token (a config change between runs).
        private func reconfigured(_ base: HookInstaller, port: UInt16, token: String = "") -> HookInstaller {
            HookInstaller(claudeDir: base.claudeDir, shimURL: base.shimURL, port: port, token: token)
        }

        private func parse(_ text: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        private func readSettings(_ i: HookInstaller) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: i.settingsURL)) as? [String: Any])
        }

        private func settingsText(_ i: HookInstaller) throws -> String {
            try String(contentsOf: i.settingsURL, encoding: .utf8)
        }

        private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
            ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        }

        private func entries(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
            groups(settings, event).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        }

        private func isBool(_ value: Any?) -> Bool {
            guard let n = value as? NSNumber else { return false }
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }

        private func backups(_ i: HookInstaller) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: i.claudeDir.path)) ?? [])
                .filter { $0.hasPrefix("settings.json.co-sheep-backup-") }
                .sorted()
        }

        private func permissions(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }

        private func seed(_ i: HookInstaller, _ text: String, mode: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: i.claudeDir, withIntermediateDirectories: true)
            try text.write(to: i.settingsURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: i.settingsURL.path)
        }

        /// A realistic settings.json: unrelated keys, bools, ints, foreign hooks.
        private let lived = #"""
        {
          "model": "opus",
          "includeCoAuthoredBy": false,
          "cleanupPeriodDays": 30,
          "bigNumber": 9007199254740993,
          "ratio": 1.5,
          "env": {"A": "1", "ENABLED": true},
          "permissions": {"allow": ["Bash(ls:*)"], "deny": []},
          "statusLine": {"type": "command", "command": "~/bin/status.sh"},
          "hooks": {
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/lint", "timeout": 10}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff", "async": false}]}
            ],
            "MyCustomEvent": [{"hooks": [{"type": "command", "command": "echo hi"}]}]
          }
        }
        """#

        // MARK: install

        @Test func installIntoAMissingFileCreatesJustHooks() throws {
            try withInstaller { i, _ in
                #expect(!FileManager.default.fileExists(atPath: i.settingsURL.path))
                try i.install()

                let settings = try readSettings(i)
                #expect(Set(settings.keys) == ["hooks"])
                let hooks = try #require(settings["hooks"] as? [String: Any])
                #expect(Set(hooks.keys) == Set(HookInstaller.events))
                #expect(HookInstaller.events.count == 14)
                for event in HookInstaller.events {
                    let g = groups(settings, event)
                    #expect(g.count == 1, "\(event)")
                    #expect(g.first?["matcher"] as? String == "*", "\(event)")
                    let es = entries(settings, event)
                    #expect(es.count == 1, "\(event)")
                    #expect(es.first?["type"] as? String == "command", "\(event)")
                    #expect(es.first?["command"] as? String == i.shimURL.path, "\(event)")
                }
                // Nothing to back up when there was no file.
                #expect(backups(i).isEmpty)
                #expect(i.status() == .installed)
            }
        }

        @Test func sessionEndIsSynchronousAndEveryOtherEventIsAsync() throws {
            try withInstaller { i, _ in
                try i.install()
                let settings = try readSettings(i)
                let end = try #require(entries(settings, "SessionEnd").first)
                #expect(end["timeout"] as? Int == 2)
                #expect(end["async"] == nil)
                for event in HookInstaller.events where event != "SessionEnd" {
                    let e = try #require(entries(settings, event).first)
                    #expect(e["async"] as? Bool == true, "\(event)")
                    #expect(isBool(e["async"]), "\(event)")
                    #expect(e["timeout"] as? Int == 5, "\(event)")
                }
            }
        }

        @Test func installWritesAnExecutablePrivateShim() throws {
            try withInstaller { i, _ in
                try i.install()
                #expect(try String(contentsOf: i.shimURL, encoding: .utf8) == i.script)
                #expect(try permissions(i.shimURL) == 0o700)
                #expect(try permissions(i.shimURL.deletingLastPathComponent()) == 0o700)
                #expect(FileManager.default.isExecutableFile(atPath: i.shimURL.path))
                #expect(try permissions(i.settingsURL) == 0o600)
            }
        }

        @Test func installKeepsEveryOtherKeyEventAndGroupExactly() throws {
            try withInstaller { i, _ in
                try seed(i, lived)
                let original = try parse(lived)
                try i.install()

                let settings = try readSettings(i)
                for (key, value) in original where key != "hooks" {
                    #expect((settings[key] as AnyObject).isEqual(value), "\(key)")
                }
                // Types survive, not just values: false stays a bool, 30 stays an int.
                #expect(isBool(settings["includeCoAuthoredBy"]))
                #expect(isBool((settings["env"] as? [String: Any])?["ENABLED"]))
                #expect(!isBool(settings["cleanupPeriodDays"]))
                let text = try settingsText(i)
                #expect(text.contains("\"includeCoAuthoredBy\" : false"))
                #expect(text.contains("\"cleanupPeriodDays\" : 30\n") || text.contains("\"cleanupPeriodDays\" : 30,"))
                #expect(text.contains("\"bigNumber\" : 9007199254740993"))
                #expect(text.contains("\"ratio\" : 1.5"))
                #expect(text.contains("\"/usr/local/bin/lint\""))

                // Foreign groups come first and unchanged; ours is appended.
                let originalHooks = try #require(original["hooks"] as? [String: Any])
                let pre = groups(settings, "PreToolUse")
                #expect(pre.count == 2)
                let foreignPre = try #require((originalHooks["PreToolUse"] as? [Any])?.first)
                #expect((pre[0] as AnyObject).isEqual(foreignPre))
                #expect(entries(settings, "PreToolUse").last?["command"] as? String == i.shimURL.path)
                let stop = groups(settings, "Stop")
                #expect(stop.count == 2)
                #expect(isBool(entries(settings, "Stop").first?["async"]))
                let custom = try #require((settings["hooks"] as? [String: Any])?["MyCustomEvent"])
                #expect((custom as AnyObject).isEqual(originalHooks["MyCustomEvent"]))
            }
        }

        @Test func installingTwiceLeavesOneGroupPerEventAndWritesNothingTheSecondTime() throws {
            try withInstaller { i, _ in
                try seed(i, lived)
                try i.install()
                let first = try Data(contentsOf: i.settingsURL)
                let backupsAfterFirst = backups(i)
                try i.install()
                try i.install()

                #expect(try Data(contentsOf: i.settingsURL) == first)
                #expect(backups(i) == backupsAfterFirst)
                let settings = try readSettings(i)
                for event in HookInstaller.events {
                    let ours = entries(settings, event).filter { $0["command"] as? String == i.shimURL.path }
                    #expect(ours.count == 1, "\(event)")
                }
                #expect(groups(settings, "PreToolUse").count == 2)
            }
        }

        @Test func installReplacesOlderCopiesOfTheShimButKeepsForeignHooksSharingAGroup() throws {
            try withInstaller { i, _ in
                try seed(i, #"""
                {"hooks": {
                  "Stop": [
                    {"matcher": "*", "hooks": [{"type": "command", "command": "/Users/old/.co-sheep/hooks/claude-hook.sh", "timeout": 5, "async": true}]}
                  ],
                  "PreToolUse": [
                    {"hooks": [
                      {"type": "command", "command": "/Users/old/.co-sheep/hooks/claude-hook.sh"},
                      {"type": "command", "command": "/usr/local/bin/lint"}
                    ]}
                  ],
                  "RetiredEvent": [
                    {"hooks": [{"type": "command", "command": "/Users/old/.co-sheep/hooks/claude-hook.sh"}]}
                  ]
                }}
                """#)
                try i.install()

                let settings = try readSettings(i)
                #expect(groups(settings, "Stop").count == 1)
                #expect(entries(settings, "Stop").first?["command"] as? String == i.shimURL.path)
                let pre = groups(settings, "PreToolUse")
                #expect(pre.count == 2)
                let kept = (pre[0]["hooks"] as? [[String: Any]]) ?? []
                #expect(kept.map { $0["command"] as? String } == ["/usr/local/bin/lint"])
                // A group that only held our old shim disappears with its event.
                #expect((settings["hooks"] as? [String: Any])?["RetiredEvent"] == nil)
            }
        }

        @Test func aShimPathWithSpacesIsQuotedInTheCommand() throws {
            try withBrainRoot { root in
                let i = HookInstaller(
                    claudeDir: root.appendingPathComponent("claude"),
                    shimURL: root.appendingPathComponent("my home/hooks/claude-hook.sh"))
                #expect(i.shimCommand == "'\(i.shimURL.path)'")
                try i.install()
                let settings = try readSettings(i)
                #expect(entries(settings, "Stop").first?["command"] as? String == i.shimCommand)
                #expect(i.status() == .installed)
                try i.install()
                #expect(groups(try readSettings(i), "Stop").count == 1)
                try i.uninstall()
                #expect(i.status() == .notInstalled)
            }
        }

        @Test func installThroughASymlinkedSettingsFileWritesTheTargetAndKeepsPermissions() throws {
            try withInstaller { i, root in
                let real = root.appendingPathComponent("dotfiles/settings.json")
                try FileManager.default.createDirectory(
                    at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
                try #"{"model":"opus"}"#.write(to: real, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
                try FileManager.default.createDirectory(at: i.claudeDir, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: i.settingsURL, withDestinationURL: real)

                try i.install()

                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: i.settingsURL.path) == real.path)
                let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any]
                #expect(settings?["model"] as? String == "opus")
                #expect(settings?["hooks"] != nil)
                #expect(try permissions(real) == 0o640)
                #expect(backups(i).count == 1)
            }
        }

        @Test func installPreservesTheModeOfAnExistingSettingsFile() throws {
            try withInstaller { i, _ in
                try seed(i, #"{"model":"opus"}"#, mode: 0o644)
                try i.install()
                #expect(try permissions(i.settingsURL) == 0o644)
            }
        }

        // MARK: refusal

        @Test func installRefusesSettingsThatAreNotAJSONObjectAndTouchesNothing() throws {
            for bad in ["{ not json", "[1, 2]", "", "\"text\"", "null", "{\"a\": 1} trailing", "{'a': 1}"] {
                try withInstaller { i, _ in
                    try seed(i, bad)
                    #expect(throws: HookInstallError.settingsNotJSON) { try i.install() }
                    #expect(try settingsText(i) == bad, "\(bad)")
                    #expect(!FileManager.default.fileExists(atPath: i.shimURL.path), "\(bad)")
                    #expect(backups(i).isEmpty, "\(bad)")
                }
            }
        }

        @Test func uninstallRefusesCorruptSettingsAndKeepsTheShim() throws {
            try withInstaller { i, _ in
                try FileManager.default.createDirectory(
                    at: i.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try i.script.write(to: i.shimURL, atomically: true, encoding: .utf8)
                try seed(i, "{ not json")

                #expect(throws: HookInstallError.settingsNotJSON) { try i.uninstall() }
                #expect(try settingsText(i) == "{ not json")
                #expect(FileManager.default.fileExists(atPath: i.shimURL.path))
                #expect(backups(i).isEmpty)
            }
        }

        @Test func unexpectedHookLayoutsAreRefusedToo() throws {
            for bad in [#"{"hooks": "nope"}"#, #"{"hooks": {"Stop": "nope"}}"#, #"{"hooks": [1]}"#] {
                try withInstaller { i, _ in
                    try seed(i, bad)
                    #expect(throws: HookInstallError.self) { try i.install() }
                    #expect(try settingsText(i) == bad)
                    #expect(!FileManager.default.fileExists(atPath: i.shimURL.path))
                }
            }
        }

        @Test func theRefusalSaysWhy() {
            let text = HookInstallError.settingsNotJSON.errorDescription ?? ""
            #expect(text == "settings.json isn't valid JSON, so co-sheep won't touch it.")
        }

        @Test func anInvalidTokenIsRefusedBeforeAnythingIsWritten() throws {
            for token in ["bad\ntoken", "tab\there", "ünicode", "\u{7F}"] {
                try withInstaller(token: token) { i, _ in
                    #expect(throws: HookInstallError.invalidToken) { try i.install() }
                    #expect(!FileManager.default.fileExists(atPath: i.shimURL.path))
                    #expect(!FileManager.default.fileExists(atPath: i.settingsURL.path))
                }
            }
        }

        // MARK: uninstall

        @Test func uninstallRestoresTheOriginalSettingsAndDeletesTheShim() throws {
            try withInstaller { i, _ in
                try seed(i, lived)
                let original = try parse(lived)
                try i.install()
                try i.uninstall()

                let settings = try readSettings(i)
                #expect((settings as NSDictionary).isEqual(original as NSDictionary))
                #expect(isBool(settings["includeCoAuthoredBy"]))
                #expect(!FileManager.default.fileExists(atPath: i.shimURL.path))
                #expect(i.status() == .notInstalled)
            }
        }

        @Test func uninstallRemovesEmptyEventArraysAndTheHooksKey() throws {
            try withInstaller { i, _ in
                try i.install()
                try i.uninstall()
                let settings = try readSettings(i)
                #expect(settings.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: i.shimURL.path))
            }
        }

        @Test func uninstallKeepsForeignHooksThatShareOurEvents() throws {
            try withInstaller { i, _ in
                try seed(i, lived)
                try i.install()
                try i.uninstall()
                let settings = try readSettings(i)
                #expect(groups(settings, "PreToolUse").count == 1)
                #expect(entries(settings, "PreToolUse").first?["command"] as? String == "/usr/local/bin/lint")
                #expect(groups(settings, "Stop").count == 1)
                #expect((settings["hooks"] as? [String: Any])?["Notification"] == nil)
            }
        }

        @Test func uninstallWithNothingInstalledWritesNothing() throws {
            try withInstaller { i, _ in
                try i.uninstall()
                #expect(!FileManager.default.fileExists(atPath: i.settingsURL.path))
                try seed(i, lived)
                let before = try Data(contentsOf: i.settingsURL)
                try i.uninstall()
                #expect(try Data(contentsOf: i.settingsURL) == before)
                #expect(backups(i).isEmpty)
            }
        }

        // MARK: backups

        @Test func everyWriteIsBackedUpFirstAndOnlyTheThreeNewestSurvive() throws {
            try withInstaller { i, _ in
                let base = Date(timeIntervalSince1970: 1_790_000_000)
                for n in 1...5 {
                    try seed(i, "{\"n\": \(n)}")
                    try i.install(now: base.addingTimeInterval(Double(n) * 10))
                }
                let names = backups(i)
                #expect(names.count == 3)
                for name in names {
                    #expect(name.wholeMatch(of: /settings\.json\.co-sheep-backup-\d{8}-\d{6}/) != nil, "\(name)")
                }
                // The survivors are the backups of installs 3, 4 and 5, byte for byte.
                let contents = try names.map {
                    try String(contentsOf: i.claudeDir.appendingPathComponent($0), encoding: .utf8)
                }
                #expect(contents == ["{\"n\": 3}", "{\"n\": 4}", "{\"n\": 5}"])
            }
        }

        @Test func backupsTakenInTheSameSecondGetDistinctNamesAndPruneInOrder() throws {
            try withInstaller { i, _ in
                let now = Date(timeIntervalSince1970: 1_790_000_000)
                for n in 1...4 {
                    try seed(i, "{\"n\": \(n)}")
                    try i.install(now: now)
                }
                let names = backups(i)
                #expect(names.count == 3)
                #expect(Set(names).count == 3)
                let contents = try names.map {
                    try String(contentsOf: i.claudeDir.appendingPathComponent($0), encoding: .utf8)
                }
                #expect(Set(contents) == ["{\"n\": 2}", "{\"n\": 3}", "{\"n\": 4}"])
            }
        }

        @Test func uninstallBacksUpToo() throws {
            try withInstaller { i, _ in
                try i.install()
                #expect(backups(i).isEmpty)
                let installed = try Data(contentsOf: i.settingsURL)
                try i.uninstall()
                let names = backups(i)
                #expect(names.count == 1)
                #expect(try Data(contentsOf: i.claudeDir.appendingPathComponent(names[0])) == installed)
            }
        }

        // MARK: status

        @Test func statusWithoutOurHooksIsNotInstalled() throws {
            try withInstaller { i, _ in
                #expect(i.status() == .notInstalled)
                try seed(i, lived)
                #expect(i.status() == .notInstalled)
                try seed(i, "{ not json")
                #expect(i.status() == .notInstalled)
                // An orphaned shim alone doesn't count.
                try FileManager.default.createDirectory(
                    at: i.shimURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try i.script.write(to: i.shimURL, atomically: true, encoding: .utf8)
                try seed(i, lived)
                #expect(i.status() == .notInstalled)
            }
        }

        @Test func statusIsStaleWhenTheShimIsMissingOrNotExecutable() throws {
            try withInstaller { i, _ in
                try i.install()
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: i.shimURL.path)
                guard case .stale(let reason) = i.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason.contains("isn't executable"))

                try FileManager.default.removeItem(at: i.shimURL)
                guard case .stale(let reason2) = i.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason2.contains("missing"))
            }
        }

        @Test func statusIsStaleWhenThePortOrTokenChanged() throws {
            try withInstaller { i, _ in
                try i.install()
                guard case .stale(let portReason) = reconfigured(i, port: 5000).status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(portReason.contains("port"))
                guard case .stale(let tokenReason) = reconfigured(i, port: 4917, token: "s3cret").status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(tokenReason.contains("token"))
                // And repairing with the new config makes it current again.
                let repaired = reconfigured(i, port: 5000, token: "s3cret")
                try repaired.install()
                #expect(repaired.status() == .installed)
                #expect(i.status() != .installed)
            }
        }

        @Test func statusIsStaleWhenTheTokenWasRemovedFromTheConfig() throws {
            try withInstaller(token: "s3cret") { i, _ in
                try i.install()
                #expect(i.status() == .installed)
                guard case .stale(let reason) = reconfigured(i, port: 4917).status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason.contains("token"))
            }
        }

        @Test func statusIsStaleWhenAnEventIsMissingOrChangedMode() throws {
            try withInstaller { i, _ in
                try i.install()
                var settings = try readSettings(i)
                var hooks = try #require(settings["hooks"] as? [String: Any])
                hooks["Stop"] = nil
                settings["hooks"] = hooks
                try JSONSerialization.data(withJSONObject: settings).write(to: i.settingsURL)
                guard case .stale(let reason) = i.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason.contains("Stop"))

                try i.install()
                #expect(i.status() == .installed)
                // SessionEnd made async by hand: no longer what we'd write.
                settings = try readSettings(i)
                hooks = try #require(settings["hooks"] as? [String: Any])
                hooks["SessionEnd"] = [["matcher": "*", "hooks": [
                    ["type": "command", "command": i.shimURL.path, "timeout": 2, "async": true] as [String: Any]
                ]] as [String: Any]]
                settings["hooks"] = hooks
                try JSONSerialization.data(withJSONObject: settings).write(to: i.settingsURL)
                guard case .stale(let reason2) = i.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason2.contains("SessionEnd"))
            }
        }

        @Test func statusIsStaleWhenTheHooksPointAtAnotherHome() throws {
            try withInstaller { i, _ in
                try seed(i, #"""
                {"hooks": {"Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "/Users/old/.co-sheep/hooks/claude-hook.sh"}]}]}}
                """#)
                guard case .stale = i.status() else {
                    Issue.record("expected stale")
                    return
                }
            }
        }

        @Test func statusIsStaleWhenTheShimTextIsFromAnotherVersion() throws {
            try withInstaller { i, _ in
                try i.install()
                try "#!/bin/sh\nexit 0\n".write(to: i.shimURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: i.shimURL.path)
                guard case .stale(let reason) = i.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason.contains("out of date"))
            }
        }

        // MARK: defaults

        @Test func defaultLocationsFollowPathsRootAndTheEnvironment() {
            withBrainRoot { root in
                #expect(HookInstaller.defaultShimURL == Paths.root.appendingPathComponent("hooks/claude-hook.sh"))
                #expect(HookInstaller.defaultShimURL.path.hasPrefix(root.path))
                let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
                if ProcessInfo.processInfo.environment["CO_SHEEP_CLAUDE_DIR"] == nil {
                    #expect(HookInstaller.defaultClaudeDir.path == home.path)
                }
            }
        }

        @Test func configSuppliesPortAndToken() {
            var config = SheepConfig()
            config.mcpPort = 5555
            config.mcpToken = "tok"
            let i = HookInstaller(
                config: config, claudeDir: URL(fileURLWithPath: "/nonexistent/claude"),
                shimURL: URL(fileURLWithPath: "/nonexistent/shim.sh"))
            #expect(i.port == 5555)
            #expect(i.token == "tok")
        }
    }
}
