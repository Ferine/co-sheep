import AppKit

// Agent herd: the "Connect Claude Code…" menu item. Touching another tool's
// config is always confirmed first, and the outcome is always reported.

/// How the flow talks to the human: `NSAlert` in the app, a fake in tests.
protocol HookPrompter {
    /// Shows the alert and returns the index of the clicked button (0 = first).
    /// A button titled "Cancel" is also bound to Escape.
    func ask(title: String, message: String, buttons: [String]) -> Int
}

extension HookPrompter {
    /// A one-button alert.
    func tell(title: String, message: String) {
        _ = ask(title: title, message: message, buttons: ["OK"])
    }
}

struct AlertPrompter: HookPrompter {
    func ask(title: String, message: String, buttons: [String]) -> Int {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        for button in buttons { alert.addButton(withTitle: button) }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}

/// Connect / Disconnect / Repair, whichever the installer's status calls for.
struct ClaudeHooksFlow {
    var prompter: any HookPrompter = AlertPrompter()
    /// nil when `config.json` exists but can't be parsed; a missing file means defaults.
    var loadConfig: () -> SheepConfig? = { ClaudeHooksFlow.configOrDefaults() }
    var makeInstaller: (SheepConfig) -> HookInstaller = { HookInstaller(config: $0) }
    /// Fired after every attempt (the menu titles refresh on it).
    var changed: () -> Void = { AppEvents.shared.herdHooksChanged.emit() }

    static func configOrDefaults() -> SheepConfig? {
        Config.loadConfig() ?? (Config.needsOnboarding() ? SheepConfig() : nil)
    }

    static func menuTitle(for status: HookInstallStatus) -> String {
        switch status {
        case .notInstalled: "Connect Claude Code…"
        case .installed: "Disconnect Claude Code"
        case .stale: "Repair Claude Code Hooks…"
        }
    }

    func status() -> HookInstallStatus {
        makeInstaller(loadConfig() ?? SheepConfig()).status()
    }

    /// The menu item was chosen.
    func perform() {
        let config = loadConfig()
        let installer = makeInstaller(config ?? SheepConfig())
        defer { changed() }
        switch installer.status() {
        case .notInstalled:
            guard canReportToServer(config) else { return }
            connect(installer, repairingBecause: nil)
        case .installed:
            disconnect(installer)
        case .stale(let reason):
            guard canReportToServer(config) else { return }
            connect(installer, repairingBecause: reason)
        }
    }

    // MARK: Steps

    /// The hooks post to co-sheep's local server: no server, nothing to connect.
    private func canReportToServer(_ config: SheepConfig?) -> Bool {
        guard let config else {
            prompter.tell(
                title: "Can't connect Claude Code",
                message: "\(Self.display(Paths.config)) couldn't be read, so co-sheep doesn't know which port to use. Fix or remove it, then try again.")
            return false
        }
        guard config.mcpEnabled else {
            prompter.tell(
                title: "co-sheep's local server is off",
                message: "Claude Code reports to co-sheep through its local server, which is turned off (mcp_enabled is false in \(Self.display(Paths.config))). Turn it on and restart co-sheep to connect Claude Code.")
            return false
        }
        return true
    }

    private func connect(_ installer: HookInstaller, repairingBecause reason: String?) {
        let settings = Self.display(installer.settingsURL)
        let promise = "The hooks only send session events to co-sheep on 127.0.0.1 and always exit 0, so they can't block or change what Claude Code does."
        let repairing = reason != nil
        let answer: Int
        if let reason {
            answer = prompter.ask(
                title: "Repair Claude Code hooks?",
                message: "The co-sheep hooks in \(settings) need repair: \(reason). Repairing rewrites the hook script and refreshes the hooks (a backup is saved first). \(promise)",
                buttons: ["Repair", "Disconnect", "Cancel"])
        } else {
            answer = prompter.ask(
                title: "Connect Claude Code?",
                message: "co-sheep will add hooks to \(settings) (a backup is saved first). \(promise) \"Disconnect Claude Code\" removes them again.",
                buttons: ["Connect", "Cancel"])
        }
        if repairing, answer == 1 {
            run(disconnecting: installer)
            return
        }
        guard answer == 0 else { return }
        do {
            try installer.install()
            prompter.tell(
                title: repairing ? "Claude Code hooks repaired" : "Claude Code connected",
                message: "Running sessions pick the hooks up on their own. Each Claude Code session shows up as a lamb as soon as it does something.")
        } catch {
            Log.info("herd", "error: couldn't install hooks: \(error.localizedDescription)")
            prompter.tell(
                title: repairing ? "Couldn't repair Claude Code hooks" : "Couldn't connect Claude Code",
                message: error.localizedDescription)
        }
    }

    private func disconnect(_ installer: HookInstaller) {
        let answer = prompter.ask(
            title: "Disconnect Claude Code?",
            message: "co-sheep will remove its hooks from \(Self.display(installer.settingsURL)) (a backup is saved first) and delete its hook script. Your other hooks and settings are left alone.",
            buttons: ["Disconnect", "Cancel"])
        guard answer == 0 else { return }
        run(disconnecting: installer)
    }

    private func run(disconnecting installer: HookInstaller) {
        do {
            try installer.uninstall()
            prompter.tell(
                title: "Claude Code disconnected",
                message: "co-sheep's hooks are gone from \(Self.display(installer.settingsURL)).")
        } catch {
            Log.info("herd", "error: couldn't remove hooks: \(error.localizedDescription)")
            prompter.tell(title: "Couldn't disconnect Claude Code", message: error.localizedDescription)
        }
    }

    private static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
