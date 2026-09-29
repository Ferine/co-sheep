import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayHost?
    private var demo: DemoDriver?
    private var clickThroughTimer: TimerToken?
    private var chatDemo: InputBubble?

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
        if ProcessInfo.processInfo.environment["CO_SHEEP_DEMO_CHAT"] != nil {
            let bubble = InputBubble(config: InputBubbleConfig(
                promptText: "Talk to me...", placeholder: "Say something...", buttonText: "Send",
                onSubmit: { _ in }, onClose: nil, shouldIgnoreClickAway: nil), host: host)
            bubble.show()
            bubble.updatePosition(600, 900, 96)
            chatDemo = bubble
            SimTimers.after(800) {
                bubble.showReply("Baaa. I have opinions about your tabs, and none of them are kind. Close some.")
                bubble.updatePosition(600, 900, 96)
            }
            SimTimers.after(1600) {
                guard let v = host.view.subviews.last,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CO_SHEEP_DEMO_CHAT"]!)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                Log.info("app", "chat snapshot \(v.frame)")
            }
        }
        if let path = ProcessInfo.processInfo.environment["CO_SHEEP_SNAPSHOT"] {
            SimTimers.after(2500) { host.snapshotPNG(to: URL(fileURLWithPath: path)) }
        }
    }
}
