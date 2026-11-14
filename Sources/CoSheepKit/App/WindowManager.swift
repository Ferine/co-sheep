import AppKit
import SwiftUI

/// The aux windows (ex-`open_*_window` in lib.rs).
enum WindowKind: CaseIterable {
    case settings, memory, friends, wardrobe, naming, friendMemory

    /// The Tauri window label.
    var label: String {
        switch self {
        case .settings: "settings"
        case .memory: "memory"
        case .friends: "friends"
        case .wardrobe: "wardrobe"
        case .naming: "naming"
        case .friendMemory: "friend_memory"
        }
    }

    var title: String {
        switch self {
        case .naming: "Name your sheep!"
        case .memory: "Sheep's Brain"
        case .settings: "co-sheep Settings"
        case .friends: "Manage Friends"
        case .wardrobe: "Wardrobe"
        case .friendMemory: "Friend Relationships"
        }
    }

    /// A line under the title, for the windows whose toolbar has room for one.
    var subtitle: String? {
        switch self {
        case .memory: "What your sheep knows, believes, and obsesses over"
        default: nil
        }
    }

    /// Size in points of the area below the window's bar (Tauri `inner_size`).
    var size: NSSize {
        switch self {
        case .naming: NSSize(width: 380, height: 200)
        case .memory: NSSize(width: 550, height: 600)
        case .settings: NSSize(width: 420, height: 600)
        case .friends: NSSize(width: 400, height: 550)
        case .wardrobe: NSSize(width: 400, height: 580)
        case .friendMemory: NSSize(width: 420, height: 500)
        }
    }

    var isResizable: Bool {
        switch self {
        case .memory, .friendMemory: true
        case .naming, .settings, .friends, .wardrobe: false
        }
    }

    /// Smallest area below the bar a resizable window can be dragged to.
    var minSize: NSSize? {
        switch self {
        case .memory: NSSize(width: 420, height: 320)
        case .friendMemory: NSSize(width: 340, height: 320)
        default: nil
        }
    }

    /// Read-only windows also refresh whenever they become key again (their
    /// data changes while the sheep lives). Forms only reload when opened, so
    /// switching away and back never discards what you were typing.
    var reloadsWhenKey: Bool {
        switch self {
        case .memory, .friendMemory: true
        case .naming, .settings, .friends, .wardrobe: false
        }
    }

    /// The "Opening … window" log line (`friend_memory` had none).
    fileprivate var openingLog: String? {
        switch self {
        case .settings: "Opening settings window"
        case .memory: "Opening memory window"
        case .friends: "Opening friends window"
        case .wardrobe: "Opening wardrobe window"
        case .naming: "Opening naming window"
        case .friendMemory: nil
        }
    }
}

/// Opens, reuses and closes the SwiftUI aux windows. One window per kind
/// (Tauri used fixed labels): opening an open kind just focuses it. Every
/// open — new or reused — reloads the window's data first. Each window is
/// floating (always on top) and centered, and the app is activated on open
/// because the overlay panel never takes focus.
///
/// Chrome (Liquid Glass): the content view runs the full height of the
/// window, under a title bar that has no background of its own, so scrolling
/// content dissolves beneath it through the system's scroll edge effect
/// rather than being cut off by an opaque strip. A view's SwiftUI `.toolbar`
/// becomes the window's toolbar, whose items the system draws as glass.
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private struct Entry {
        let window: NSWindow
        let model: any WindowModel
    }

    private var entries: [WindowKind: Entry] = [:]

    private override init() { super.init() }

    /// The open window of `kind`, if any.
    func window(for kind: WindowKind) -> NSWindow? { entries[kind]?.window }

    /// The open window's data model (for reload checks).
    func model(for kind: WindowKind) -> (any WindowModel)? { entries[kind]?.model }

    func isOpen(_ kind: WindowKind) -> Bool { entries[kind] != nil }

    func open(_ kind: WindowKind) {
        if let entry = entries[kind] {
            if kind == .naming {
                Log.info("app", "Naming window already exists, skipping")
            }
            // Bringing a form forward must not discard what's typed in it
            if kind.reloadsWhenKey { entry.model.reload() }
            present(entry.window)
            return
        }
        if let line = kind.openingLog { Log.info("app", line) }
        let entry = makeEntry(for: kind)
        entries[kind] = entry
        entry.model.reload()
        // The view's toolbar may only reach the window now, making its bar taller
        Self.setLayoutSize(kind.size, of: entry.window)
        entry.window.center()
        present(entry.window)
    }

    func close(_ kind: WindowKind) {
        entries[kind]?.window.close()
    }

    private func present(_ window: NSWindow) {
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = entries.first(where: { $0.value.window === window })?.key else { return }
        entries[kind] = nil
    }

    /// Keeps a resizable window at or above its kind's minimum. (Done here
    /// rather than with `contentMinSize`: the hosting controller resets that
    /// to zero on its next SwiftUI update.)
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let kind = entries.first(where: { $0.value.window === sender })?.key,
              let minSize = kind.minSize else { return frameSize }
        return NSSize(width: max(frameSize.width, minSize.width),
                      height: max(frameSize.height, minSize.height + Self.barHeight(of: sender)))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (kind, entry) = entries.first(where: { $0.value.window === window }),
              kind.reloadsWhenKey else { return }
        entry.model.reload()
    }

    // MARK: Construction

    private func makeEntry(for kind: WindowKind) -> Entry {
        let model: any WindowModel
        let controller: NSViewController
        switch kind {
        case .settings:
            let m = SettingsModel()
            model = m
            controller = hosting(SettingsView(model: m), for: kind)
        case .memory:
            let m = BrainModel()
            model = m
            controller = hosting(BrainView(model: m), for: kind)
        case .friends:
            let m = FriendsModel()
            model = m
            controller = hosting(FriendsView(model: m), for: kind)
        case .wardrobe:
            let m = WardrobeModel()
            model = m
            controller = hosting(WardrobeView(model: m), for: kind)
        case .naming:
            let m = NamingModel()
            model = m
            controller = hosting(NamingView(model: m), for: kind)
        case .friendMemory:
            let m = FriendMemoryModel()
            model = m
            controller = hosting(FriendMemoryView(model: m), for: kind)
        }

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if kind.isResizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: kind.size),
            styleMask: style, backing: .buffered, defer: false)
        window.title = kind.title
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        // Setting the controller sizes the window to its content; pin the
        // area below the bar to the Tauri `inner_size`.
        Self.setLayoutSize(kind.size, of: window)
        window.level = .floating // always_on_top
        window.isReleasedWhenClosed = false
        window.delegate = self
        return Entry(window: window, model: model)
    }

    /// SwiftUI content that fills the window instead of resizing it. The
    /// view's `.toolbar` items go to the window, and so do the kind's title
    /// and subtitle (the bridge owns them once a toolbar exists: a subtitle
    /// set on the `NSWindow` directly is wiped).
    private func hosting<V: View>(_ view: V, for kind: WindowKind) -> NSViewController {
        let controller = NSHostingController(
            rootView: view
                .navigationTitle(kind.title)
                .navigationSubtitle(kind.subtitle ?? ""))
        controller.sizingOptions = []
        controller.sceneBridgingOptions = .all
        return controller
    }

    /// Height of the title bar (and toolbar) the content runs under.
    static func barHeight(of window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    /// The part of the window below its bar: what the content can use
    /// without being covered.
    static func layoutSize(of window: NSWindow) -> NSSize {
        window.contentLayoutRect.size
    }

    /// Size the window so that the area below its bar is `size`. (With a
    /// full-size content view the frame also covers the bar.)
    static func setLayoutSize(_ size: NSSize, of window: NSWindow) {
        window.setContentSize(size)
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: size.width, height: size.height + barHeight(of: window)))
    }
}
