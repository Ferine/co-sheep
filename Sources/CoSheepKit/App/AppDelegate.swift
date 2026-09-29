import AppKit

/// Ex-lib.rs `run()` + `setup()`: overlay, menus, backend startup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayHost?
    private var controller: AppController?
    private var menus: Menus?
    private var demo: DemoDriver?
    private var clickThroughTimer: TimerToken?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app", "=== co-sheep starting ===")

        // Main overlay — starts click-through (OverlayPanel default).
        let host = OverlayHost()
        overlay = host
        Log.info("app", "Click-through enabled on main window")

        let controller = AppController()
        self.controller = controller

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
            quit: { NSApp.terminate(nil) }
        ))
        menus.install()
        self.menus = menus

        // TEMPORARY until the Flock lands: demo driver on the overlay.
        let demo = DemoDriver(screen: host.screenSize)
        host.scene.driver = demo
        self.demo = demo
        clickThroughTimer = SimTimers.every(50) { [weak self] in
            guard let self, let overlay = self.overlay, let demo = self.demo else { return }
            overlay.updateClickThrough(bounds: demo.bounds, forceInteractive: false)
        }
        if let path = ProcessInfo.processInfo.environment["CO_SHEEP_SNAPSHOT"] {
            SimTimers.after(2500) { host.snapshotPNG(to: URL(fileURLWithPath: path)) }
        }

        controller.start()
    }

    // The overlay panel and aux windows come and go; the app lives in the tray.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
