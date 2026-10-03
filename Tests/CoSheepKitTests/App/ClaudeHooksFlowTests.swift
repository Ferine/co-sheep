import AppKit
import Foundation
import Testing
@testable import CoSheepKit

// Agent herd: the "Connect Claude Code…" menu item and its confirm/report
// flow. Alerts are faked; the installer works on temp dirs only.

/// Answers `ask` from a queue (default: the first button) and records everything shown.
final class FakePrompter: HookPrompter {
    struct Shown: Equatable {
        var title: String
        var message: String
        var buttons: [String]
    }

    var answers: [Int]
    private(set) var shown: [Shown] = []

    init(answers: [Int] = []) { self.answers = answers }

    func ask(title: String, message: String, buttons: [String]) -> Int {
        shown.append(Shown(title: title, message: message, buttons: buttons))
        return answers.isEmpty ? 0 : answers.removeFirst()
    }
}

extension BrainTests {
    @Suite("claude hooks flow")
    struct ClaudeHooksFlowTests {
        private struct Rig {
            var flow: ClaudeHooksFlow
            var prompter: FakePrompter
            var installer: HookInstaller
            var changes: Captured<Void>
        }

        private func withRig<T>(
            answers: [Int] = [], config: SheepConfig? = SheepConfig(), _ body: (Rig) throws -> T
        ) throws -> T {
            try withBrainRoot { root in
                let installer = HookInstaller(
                    claudeDir: root.appendingPathComponent("claude"),
                    shimURL: Paths.dir("hooks").appendingPathComponent("claude-hook.sh"))
                let prompter = FakePrompter(answers: answers)
                let changes = Captured(AppEvents.shared.herdHooksChanged)
                defer { changes.stop() }
                var flow = ClaudeHooksFlow()
                flow.prompter = prompter
                flow.loadConfig = { config }
                flow.makeInstaller = { c in
                    HookInstaller(
                        claudeDir: installer.claudeDir, shimURL: installer.shimURL,
                        port: c.mcpPort, token: c.mcpToken)
                }
                return try body(Rig(flow: flow, prompter: prompter, installer: installer, changes: changes))
            }
        }

        private func seedSettings(_ rig: Rig, _ text: String) throws {
            try FileManager.default.createDirectory(at: rig.installer.claudeDir, withIntermediateDirectories: true)
            try text.write(to: rig.installer.settingsURL, atomically: true, encoding: .utf8)
        }

        // MARK: titles and menus

        @Test func titlesFollowTheStatus() {
            #expect(ClaudeHooksFlow.menuTitle(for: .notInstalled) == "Connect Claude Code…")
            #expect(ClaudeHooksFlow.menuTitle(for: .installed) == "Disconnect Claude Code")
            #expect(ClaudeHooksFlow.menuTitle(for: .stale("shim missing")) == "Repair Claude Code Hooks…")
        }

        @Test func debugMenuHasTheHerdDemoCommands() {
            let commands = Menus.debugItems.map(\.command)
            #expect(commands.contains("herd:demo"))
            #expect(commands.contains("herd:clear-demo"))
            #expect(Menus.debugItems.first { $0.command == "herd:demo" }?.title == "Herd: Demo Flock")
            #expect(Menus.debugItems.first { $0.command == "herd:clear-demo" }?.title == "Herd: Clear Demo")
            #expect(Set(commands).count == commands.count)
        }

        private func menuActions(status: @escaping () -> HookInstallStatus) -> MenuActions {
            MenuActions(
                settings: {}, memory: {}, friends: {}, friendRelationships: {}, wardrobe: {}, chat: {},
                captureMoment: {}, commentNow: {}, togglePause: {}, debugCapture: {}, debugCommand: { _ in },
                claudeHooksStatus: status, toggleClaudeHooks: {}, quit: {})
        }

        @Test func menuItemsRefreshWhenTheMenuOpensAndWhenTheHooksChange() {
            var status = HookInstallStatus.notInstalled
            let menus = Menus(actions: menuActions { status })
            let statusItem = menus.claudeItem()
            let appItem = menus.claudeItem()
            menus.observeHookChanges()
            #expect(statusItem.title == "Connect Claude Code…")

            // Opening either menu re-reads the status.
            status = .installed
            menus.menuNeedsUpdate(NSMenu())
            #expect(statusItem.title == "Disconnect Claude Code")
            #expect(appItem.title == "Disconnect Claude Code")

            // A change while a menu is up arrives as a signal.
            status = .stale("the hook script is missing")
            AppEvents.shared.herdHooksChanged.emit()
            #expect(statusItem.title == "Repair Claude Code Hooks…")
            #expect(appItem.title == "Repair Claude Code Hooks…")
        }

        // MARK: config

        @Test func configOrDefaultsReadsDefaultsParsesAndRefusesCorruptFiles() throws {
            try withBrainRoot { _ in
                #expect(ClaudeHooksFlow.configOrDefaults() == SheepConfig())
                var config = SheepConfig()
                config.mcpPort = 5001
                try Config.writeConfig(config)
                #expect(ClaudeHooksFlow.configOrDefaults()?.mcpPort == 5001)
                try write("{ not json", to: Paths.config)
                #expect(ClaudeHooksFlow.configOrDefaults() == nil)
            }
        }

        // MARK: connect

        @Test func connectConfirmsFirstThenInstallsAndReports() throws {
            try withRig { rig in
                #expect(rig.flow.status() == .notInstalled)
                rig.flow.perform()

                #expect(rig.prompter.shown.count == 2)
                let confirm = rig.prompter.shown[0]
                #expect(confirm.title == "Connect Claude Code?")
                #expect(confirm.buttons == ["Connect", "Cancel"])
                #expect(confirm.message.contains("settings.json"))
                #expect(confirm.message.contains("backup"))
                #expect(confirm.message.contains("127.0.0.1"))
                #expect(confirm.message.contains("always exit 0"))
                #expect(confirm.message.contains("Disconnect Claude Code"))
                #expect(rig.prompter.shown[1].title == "Claude Code connected")
                #expect(rig.prompter.shown[1].buttons == ["OK"])

                #expect(rig.installer.status() == .installed)
                #expect(rig.flow.status() == .installed)
                #expect(rig.changes.values.count == 1)
            }
        }

        @Test func cancellingTouchesNothing() throws {
            try withRig(answers: [1]) { rig in
                rig.flow.perform()
                #expect(rig.prompter.shown.count == 1)
                #expect(!FileManager.default.fileExists(atPath: rig.installer.settingsURL.path))
                #expect(!FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
            }
        }

        @Test func connectUsesThePortAndTokenFromTheConfig() throws {
            var config = SheepConfig()
            config.mcpPort = 5123
            config.mcpToken = "tok"
            try withRig(config: config) { rig in
                rig.flow.perform()
                let shim = try String(contentsOf: rig.installer.shimURL, encoding: .utf8)
                #expect(shim.contains("127.0.0.1:5123/hook"))
                #expect(shim.contains("Bearer tok"))
            }
        }

        @Test func connectReportsAnUnreadableSettingsFileWithoutTouchingIt() throws {
            try withRig { rig in
                try seedSettings(rig, "{ not json")
                rig.flow.perform()

                #expect(rig.prompter.shown.count == 2)
                let failure = rig.prompter.shown[1]
                #expect(failure.title == "Couldn't connect Claude Code")
                #expect(failure.message == "settings.json isn't valid JSON, so co-sheep won't touch it.")
                #expect(try String(contentsOf: rig.installer.settingsURL, encoding: .utf8) == "{ not json")
                #expect(!FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
                #expect(rig.changes.values.count == 1)
            }
        }

        @Test func aServerThatIsOffExplainsAndOffersNothing() throws {
            var config = SheepConfig()
            config.mcpEnabled = false
            try withRig(config: config) { rig in
                rig.flow.perform()
                #expect(rig.prompter.shown.count == 1)
                let alert = rig.prompter.shown[0]
                #expect(alert.title == "co-sheep's local server is off")
                #expect(alert.buttons == ["OK"])
                #expect(alert.message.contains("mcp_enabled"))
                #expect(!FileManager.default.fileExists(atPath: rig.installer.settingsURL.path))
                #expect(!FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
            }
        }

        @Test func anUnreadableConfigExplainsAndInstallsNothing() throws {
            try withRig(config: nil) { rig in
                rig.flow.perform()
                #expect(rig.prompter.shown.count == 1)
                #expect(rig.prompter.shown[0].title == "Can't connect Claude Code")
                #expect(rig.prompter.shown[0].buttons == ["OK"])
                #expect(!FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
            }
        }

        // MARK: disconnect

        @Test func disconnectConfirmsThenRemovesOnlyOurHooks() throws {
            try withRig { rig in
                try seedSettings(rig, #"{"model":"opus"}"#)
                rig.flow.perform() // connect
                #expect(rig.flow.status() == .installed)

                rig.flow.perform() // disconnect
                let confirm = rig.prompter.shown[2]
                #expect(confirm.title == "Disconnect Claude Code?")
                #expect(confirm.buttons == ["Disconnect", "Cancel"])
                #expect(confirm.message.contains("settings.json"))
                #expect(confirm.message.contains("backup"))
                #expect(rig.prompter.shown[3].title == "Claude Code disconnected")

                #expect(rig.flow.status() == .notInstalled)
                let text = try String(contentsOf: rig.installer.settingsURL, encoding: .utf8)
                #expect(text.contains("\"model\""))
                #expect(!text.contains("hooks"))
                #expect(!FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
                #expect(rig.changes.values.count == 2)
            }
        }

        @Test func disconnectCanBeCancelled() throws {
            try withRig(answers: [0, 0, 1]) { rig in
                rig.flow.perform() // connect + report
                rig.flow.perform() // disconnect confirm -> Cancel
                #expect(rig.flow.status() == .installed)
                #expect(FileManager.default.fileExists(atPath: rig.installer.shimURL.path))
            }
        }

        @Test func settingsCorruptedAfterConnectingReadAsNotInstalledAndConnectRefuses() throws {
            try withRig { rig in
                rig.flow.perform()
                #expect(rig.flow.status() == .installed)
                try "{ broken".write(to: rig.installer.settingsURL, atomically: true, encoding: .utf8)
                // Unparseable settings read as "not installed", so the menu offers Connect again,
                // and Connect refuses with the reason.
                rig.flow.perform()
                #expect(rig.prompter.shown.last?.title == "Couldn't connect Claude Code")
                #expect(try String(contentsOf: rig.installer.settingsURL, encoding: .utf8) == "{ broken")
            }
        }

        // MARK: repair

        @Test func repairRewritesAMissingShim() throws {
            try withRig { rig in
                rig.flow.perform() // connect
                try FileManager.default.removeItem(at: rig.installer.shimURL)
                guard case .stale(let reason) = rig.flow.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(ClaudeHooksFlow.menuTitle(for: rig.flow.status()) == "Repair Claude Code Hooks…")

                rig.flow.perform()
                let confirm = rig.prompter.shown[2]
                #expect(confirm.title == "Repair Claude Code hooks?")
                #expect(confirm.buttons == ["Repair", "Disconnect", "Cancel"])
                #expect(confirm.message.contains(reason))
                #expect(rig.prompter.shown[3].title == "Claude Code hooks repaired")
                #expect(rig.flow.status() == .installed)
            }
        }

        @Test func repairCanDisconnectInstead() throws {
            try withRig(answers: [0, 0, 1]) { rig in
                rig.flow.perform()
                try FileManager.default.removeItem(at: rig.installer.shimURL)
                rig.flow.perform() // repair prompt -> Disconnect
                #expect(rig.prompter.shown.last?.title == "Claude Code disconnected")
                #expect(rig.flow.status() == .notInstalled)
            }
        }

        @Test func repairCanBeCancelled() throws {
            try withRig(answers: [0, 0, 2]) { rig in
                rig.flow.perform()
                try FileManager.default.removeItem(at: rig.installer.shimURL)
                rig.flow.perform() // repair prompt -> Cancel
                #expect(rig.prompter.shown.count == 3)
                guard case .stale = rig.flow.status() else {
                    Issue.record("expected stale")
                    return
                }
            }
        }

        @Test func aChangedPortIsRepairedFromTheConfig() throws {
            var config = SheepConfig()
            try withRig(config: config) { rig in
                rig.flow.perform()
                config.mcpPort = 6000
                var moved = rig.flow
                moved.loadConfig = { config }
                guard case .stale(let reason) = moved.status() else {
                    Issue.record("expected stale")
                    return
                }
                #expect(reason.contains("port"))
                moved.perform()
                #expect(moved.status() == .installed)
                let shim = try String(contentsOf: rig.installer.shimURL, encoding: .utf8)
                #expect(shim.contains("127.0.0.1:6000/hook"))
            }
        }
    }
}
