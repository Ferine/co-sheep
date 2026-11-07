import AppKit
import CoreGraphics

// Sleep, wake, display sleep, screen lock, screen saver and fast user
// switching: the moments nobody is looking at the screen, or the clock jumped
// because every process was frozen. Published on `AppEvents.power`.

nonisolated enum PowerEvent: Equatable, Sendable {
    /// System sleep: the Mac is about to freeze every process / just thawed.
    case willSleep, didWake
    case screensDidSleep, screensDidWake
    case locked, unlocked
    case screensaverStarted, screensaverStopped
    /// Fast user switching: this login session left / regained the console.
    case sessionResigned, sessionActive
}

/// Whether anyone can see this session's screen, folded from `PowerEvent`s.
/// The sources are independent (a locked screen can also sleep, a sleeping
/// Mac was usually locked first) and any combination is legal, so they stay
/// separate flags and "away" is derived rather than a state of its own.
nonisolated struct Presence: Equatable, Sendable {
    var asleep = false
    var screensAsleep = false
    var locked = false
    var screensaver = false
    var switchedOut = false

    var isAway: Bool { asleep || screensAsleep || locked || screensaver || switchedOut }

    mutating func apply(_ event: PowerEvent) {
        switch event {
        case .willSleep: asleep = true
        case .didWake: asleep = false
        case .screensDidSleep: screensAsleep = true
        case .screensDidWake: screensAsleep = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .screensaverStarted: screensaver = true
        case .screensaverStopped: screensaver = false
        case .sessionResigned: switchedOut = true
        case .sessionActive: switchedOut = false
        }
    }
}

/// One event and the presence after it.
nonisolated struct PowerChange: Equatable, Sendable {
    let event: PowerEvent
    let presence: Presence
}

/// The session's lock / console state as CoreGraphics reports it right now.
nonisolated struct SessionProbe: Equatable, Sendable {
    var locked: Bool
    var onConsole: Bool
}

/// Watches the workspace and distributed notifications and publishes each
/// power event with the folded `Presence`. A missed "unlocked" must not park
/// the sheep forever, so the lock and console flags are re-read from
/// CoreGraphics at start and whenever the Mac or its screens wake.
final class PowerMonitor {
    private let events: AppEvents
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let probe: () -> SessionProbe?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private(set) var presence = Presence()

    /// - Parameters:
    ///   - workspaceCenter: `NSWorkspace.shared.notificationCenter` (sleep,
    ///     wake, displays, session). Tests pass a plain center.
    ///   - distributedCenter: the distributed center (screen lock, screen
    ///     saver). Tests pass a plain center.
    ///   - probe: the live session state; nil when unavailable.
    init(
        events: AppEvents = .shared,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        probe: @escaping () -> SessionProbe? = { PowerMonitor.probeSession() }
    ) {
        self.events = events
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.probe = probe
    }

    var isRunning: Bool { !observers.isEmpty }

    static let workspaceEvents: [(Notification.Name, PowerEvent)] = [
        (NSWorkspace.willSleepNotification, .willSleep),
        (NSWorkspace.didWakeNotification, .didWake),
        (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
        (NSWorkspace.screensDidWakeNotification, .screensDidWake),
        (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
    ]

    static let distributedEvents: [(Notification.Name, PowerEvent)] = [
        (Notification.Name("com.apple.screenIsLocked"), .locked),
        (Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
        (Notification.Name("com.apple.screensaver.didstart"), .screensaverStarted),
        (Notification.Name("com.apple.screensaver.didstop"), .screensaverStopped),
    ]

    /// Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        resync()
        Log.info("power", "watching sleep/lock (\(presence.isAway ? "away" : "someone's looking") at start)")
        for (center, table) in [(workspaceCenter, Self.workspaceEvents), (distributedCenter, Self.distributedEvents)] {
            for (name, event) in table {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handle(event) }
                }
                observers.append((center, token))
            }
        }
    }

    func stop() {
        for o in observers { o.center.removeObserver(o.token) }
        observers.removeAll()
    }

    /// Fold one event and publish it. Internal so tests can drive it.
    func handle(_ event: PowerEvent) {
        presence.apply(event)
        if event == .didWake || event == .screensDidWake || event == .sessionActive { resync() }
        Log.info("power", "\(event)\(presence.isAway ? " (away)" : "")")
        events.power.emit(PowerChange(event: event, presence: presence))
    }

    /// Take the lock and console flags from the live session, if it answers.
    private func resync() {
        guard let p = probe() else { return }
        presence.locked = p.locked
        presence.switchedOut = !p.onConsole
    }

    /// `CGSessionCopyCurrentDictionary`: `CGSSessionScreenIsLocked` (absent
    /// when unlocked) and `kCGSessionOnConsoleKey`.
    nonisolated static func probeSession() -> SessionProbe? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (dict["kCGSessionOnConsoleKey"] as? Bool) ?? true
        return SessionProbe(locked: locked, onConsole: onConsole)
    }
}
