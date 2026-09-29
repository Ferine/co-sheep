import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayHost?
    private var demo: DemoDriver?
    private var clickThroughTimer: TimerToken?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app", "=== co-sheep starting ===")
        let host = OverlayHost()
        let demo = DemoDriver(screen: host.screenSize)
        host.scene.driver = demo
        overlay = host
        self.demo = demo
        clickThroughTimer = SimTimers.every(50) { [weak self] in
            guard let self, let overlay = self.overlay, let demo = self.demo else { return }
            overlay.updateClickThrough(bounds: demo.bounds, forceInteractive: false)
        }
        SimTimers.after(1000) { Log.info("app", "timer fired") }
        if let path = ProcessInfo.processInfo.environment["CO_SHEEP_SNAPSHOT"] {
            SimTimers.after(2500) { host.snapshotPNG(to: URL(fileURLWithPath: path)) }
        }
    }
}
