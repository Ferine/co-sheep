import AppKit

/// Menu actions (ex-tray `on_menu_event` / app `on_menu_event` in lib.rs).
struct MenuActions {
    var settings: () -> Void
    var memory: () -> Void
    var friends: () -> Void
    var wardrobe: () -> Void
    var chat: () -> Void
    var captureMoment: () -> Void
    var commentNow: () -> Void
    var togglePause: () -> Void
    var debugCapture: () -> Void
    /// "force-feud" | "spectacle:<type>" | "app-switch"
    var debugCommand: (String) -> Void
    var quit: () -> Void
}

/// Status-bar item + main menu with the same items as the Tauri app.
final class Menus: NSObject {
    private let actions: MenuActions
    private var statusItem: NSStatusItem?

    // Debug submenu — every item maps to a debug-command.
    static let debugItems: [(title: String, command: String)] = [
        ("Force Feud", "force-feud"),
        ("Spectacle: Wolf", "spectacle:wolf"),
        ("Spectacle: UFO", "spectacle:ufo"),
        ("Spectacle: Merchant", "spectacle:merchant"),
        ("Spectacle: Balloon", "spectacle:balloon"),
        ("Spectacle: Shearing", "spectacle:shearing"),
        ("Spectacle: Showdown", "spectacle:showdown"),
        ("Spectacle: Feast", "spectacle:feast"),
        ("Simulate App Switch", "app-switch"),
    ]

    init(actions: MenuActions) {
        self.actions = actions
        super.init()
    }

    func install() {
        installStatusItem()
        installMainMenu()
        Log.info("tray", "System tray created")
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func debugSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Debug")
        for (idx, d) in Self.debugItems.enumerated() {
            let i = item(d.title, #selector(debugItem(_:)))
            i.tag = idx
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func installStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = ResourceFiles.nsImage("TrayIcon.png") {
            img.size = NSSize(width: 18, height: 18)
            si.button?.image = img
        } else {
            si.button?.title = "🐑"
        }
        // Tray menu: Settings, Brain, Friends, Wardrobe, Chat, Capture, Comment Now, Pause, Debug, Quit
        let m = NSMenu()
        m.addItem(item("Settings...", #selector(settings)))
        m.addItem(item("Sheep's Brain...", #selector(memory)))
        m.addItem(item("Manage Friends...", #selector(friends)))
        m.addItem(item("Wardrobe...", #selector(wardrobe)))
        m.addItem(item("Chat with Sheep...", #selector(chat)))
        m.addItem(item("Capture Moment", #selector(captureMoment)))
        m.addItem(item("Comment Now", #selector(commentNow)))
        m.addItem(item("Pause Commentary", #selector(togglePause)))
        m.addItem(debugSubmenu())
        m.addItem(item("Quit co-sheep", #selector(quit)))
        si.menu = m
        statusItem = si
    }

    private func installMainMenu() {
        let main = NSMenu()

        // App menu: same items as the Tauri "co-sheep" submenu (+ Debug Capture).
        let appItem = NSMenuItem()
        let app = NSMenu(title: "co-sheep")
        app.addItem(item("Settings...", #selector(settings), key: ","))
        app.addItem(item("Sheep's Brain...", #selector(memory)))
        app.addItem(item("Manage Friends...", #selector(friends)))
        app.addItem(item("Wardrobe...", #selector(wardrobe)))
        app.addItem(item("Chat with Sheep...", #selector(chat)))
        app.addItem(item("Capture Moment", #selector(captureMoment)))
        app.addItem(item("Comment Now", #selector(commentNow)))
        app.addItem(item("Pause Commentary", #selector(togglePause)))
        app.addItem(item("Debug Capture...", #selector(debugCapture)))
        app.addItem(debugSubmenu())
        app.addItem(.separator())
        app.addItem(item("Quit co-sheep", #selector(quit), key: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        // Standard Edit menu so ⌘C/⌘V/⌘A/⌘Z work in text fields (chat, settings).
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // Window menu so ⌘W closes aux windows.
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    @objc private func settings() { log("settings"); actions.settings() }
    @objc private func memory() { log("memory"); actions.memory() }
    @objc private func friends() { log("friends"); actions.friends() }
    @objc private func wardrobe() { log("wardrobe"); actions.wardrobe() }
    @objc private func chat() { log("chat"); actions.chat() }
    @objc private func captureMoment() { log("capture_moment"); actions.captureMoment() }
    @objc private func commentNow() { log("comment_now"); actions.commentNow() }
    @objc private func togglePause() { log("pause"); actions.togglePause() }
    @objc private func debugCapture() { log("debug_capture"); actions.debugCapture() }
    @objc private func quit() { log("quit"); actions.quit() }

    @objc private func debugItem(_ sender: NSMenuItem) {
        guard Self.debugItems.indices.contains(sender.tag) else { return }
        let cmd = Self.debugItems[sender.tag].command
        log("debug:\(cmd)")
        actions.debugCommand(cmd)
    }

    private func log(_ id: String) { Log.info("tray", "Menu event: \(id)") }
}
