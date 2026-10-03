import AppKit

/// Ex-lib.rs `run()` + `setup()`: overlay, menus, backend startup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayHost?
    private var controller: AppController?
    private var menus: Menus?
    private var overlayController: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app", "=== co-sheep starting ===")

        // Main overlay — starts click-through (OverlayPanel default).
        let host = OverlayHost()
        overlay = host
        Log.info("app", "Click-through enabled on main window")

        let controller = AppController()
        self.controller = controller

        let claudeHooks = ClaudeHooksFlow()
        let menus = Menus(actions: MenuActions(
            settings: { WindowManager.shared.open(.settings) },
            memory: { WindowManager.shared.open(.memory) },
            friends: { WindowManager.shared.open(.friends) },
            friendRelationships: { WindowManager.shared.open(.friendMemory) },
            wardrobe: { WindowManager.shared.open(.wardrobe) },
            chat: { AppEvents.shared.openChat.emit() },
            captureMoment: { AppEvents.shared.captureMoment.emit() },
            commentNow: { controller.commentNow() },
            togglePause: { controller.togglePause() },
            debugCapture: { controller.debugCaptureFromMenu() },
            debugCommand: { AppEvents.shared.debugCommand.emit($0) },
            claudeHooksStatus: { claudeHooks.status() },
            toggleClaudeHooks: { claudeHooks.perform() },
            quit: { NSApp.terminate(nil) }
        ))
        menus.install()
        self.menus = menus

        let overlayController = OverlayController(host: host, app: controller)
        overlayController.start()
        self.overlayController = overlayController

        // Dev aid: CO_SHEEP_SNAPSHOT=/path.png [CO_SHEEP_SNAPSHOT_DELAY_MS=…]
        let env = ProcessInfo.processInfo.environment
        if let path = env["CO_SHEEP_SNAPSHOT"] {
            let delay = env["CO_SHEEP_SNAPSHOT_DELAY_MS"].flatMap(Double.init) ?? 2500
            SimTimers.after(delay) { host.snapshotPNG(to: URL(fileURLWithPath: path)) }
        }

        controller.start()
    }

    // The overlay panel and aux windows come and go; the app lives in the tray.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
