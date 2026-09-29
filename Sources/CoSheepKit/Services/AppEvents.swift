import Foundation

/// Multi-subscriber typed callback list.
final class Signal<T> {
    private var handlers: [(id: Int, fn: (T) -> Void)] = []
    private var nextId = 0

    @discardableResult
    func on(_ fn: @escaping (T) -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        handlers.append((id, fn))
        return { [weak self] in self?.handlers.removeAll { $0.id == id } }
    }

    func emit(_ value: T) {
        for h in handlers { h.fn(value) }
    }
}

extension Signal where T == Void {
    func emit() { emit(()) }
}

/// Backend → overlay events (replaces Tauri `app.emit` / webview `listen`).
final class AppEvents {
    static let shared = AppEvents()

    /// ex-"sheep-commentary": vision/chat/permission lines for the main sheep.
    let sheepCommentary = Signal<CommentaryEvent>()
    /// ex-"sheep-session": MCP session snapshots.
    let sheepSession = Signal<SessionEvent>()
    /// ex-"app-switched": frontmost app changed.
    let appSwitched = Signal<AppSwitch>()
    /// ex-"open-chat"
    let openChat = Signal<Void>()
    /// ex-"capture-moment"
    let captureMoment = Signal<Void>()
    /// ex-"debug-command": "force-feud" | "spectacle:<type>" | "app-switch"
    let debugCommand = Signal<String>()
    /// ex-"add-friend"
    let addFriend = Signal<FriendConfig>()
    /// ex-"remove-friend": friend id
    let removeFriend = Signal<String>()
    /// ex-"accessories-changed": main sheep accessories
    let accessoriesChanged = Signal<[String]>()
    /// ex-"friend-accessories-changed"
    let friendAccessoriesChanged = Signal<(id: String, accessories: [String])>()
    /// ex-"naming-complete": the new sheep name
    let namingComplete = Signal<String>()
    /// Settings saved (personality, modes, break reminders…) — the overlay re-reads config.
    let settingsChanged = Signal<Void>()
}
