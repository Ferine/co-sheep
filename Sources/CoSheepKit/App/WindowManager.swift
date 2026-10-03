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

    /// Content size in points (Tauri `inner_size`).
    var size: NSSize {
        switch self {
        case .naming: NSSize(width: 380, height: 180)
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

    /// Smallest content size a resizable window can be dragged to.
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
            controller = hosting(SettingsView(model: m))
        case .memory:
            let m = BrainModel()
            model = m
            controller = hosting(BrainView(model: m))
        case .friends:
            let m = FriendsModel()
            model = m
            controller = hosting(FriendsView(model: m))
        case .wardrobe:
            let m = WardrobeModel()
            model = m
            controller = hosting(WardrobeView(model: m))
        case .naming:
            let m = NamingModel()
            model = m
            controller = hosting(NamingView(model: m))
        case .friendMemory:
            let m = FriendMemoryModel()
            model = m
            controller = hosting(FriendMemoryView(model: m))
        }

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if kind.isResizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: kind.size),
            styleMask: style, backing: .buffered, defer: false)
        window.title = kind.title
        window.contentViewController = controller
        // Setting the controller sizes the window to its content; pin it to
        // the Tauri `inner_size`.
        window.setContentSize(kind.size)
        if let minSize = kind.minSize { window.contentMinSize = minSize }
        window.level = .floating // always_on_top
        window.isReleasedWhenClosed = false
        window.delegate = self
        return Entry(window: window, model: model)
    }

    /// SwiftUI content that fills the window instead of resizing it.
    private func hosting<V: View>(_ view: V) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }
}
