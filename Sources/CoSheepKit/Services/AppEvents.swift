import Foundation

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
    /// ex-"settings-changed": the saved config (personality, modes, break reminders…).
    let settingsChanged = Signal<SheepConfig>()
    /// Agent herd: one folded hook/transcript/liveness change (HerdStore → lambs).
    let herd = Signal<HerdChange>()
    /// Agent herd: "Connect Claude Code" state changed (installer → menu).
    let herdHooksChanged = Signal<Void>()
    /// Sleep / wake / lock / screen saver / user switch, with who can see the screen.
    let power = Signal<PowerChange>()
}
