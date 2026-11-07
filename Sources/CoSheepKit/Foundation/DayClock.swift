import Foundation

/// The local calendar day, and a signal when it changes. Most day rollovers
/// are lazy (checked on the next access), which is fine for counters but not
/// for work that must happen once a day whether or not anything asks, like
/// friend-affinity decay. `check()` runs on the system's day-changed and
/// time-zone notifications and on wake; it is cheap, so callers may add more.
final class DayClock {
    /// The day, `yyyy-MM-dd`, in `SimClock.timeZone` (same as the journal).
    static func today() -> String { BrainTime.today() }

    /// Emits the new day once per change.
    let dayChanged = Signal<String>()
    private(set) var current: String
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
        current = Self.today()
    }

    /// Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
    }

    func stop() {
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    /// Emit `dayChanged` if the local day is no longer `current`.
    func check() {
        let today = Self.today()
        guard today != current else { return }
        current = today
        Log.info("app", "a new day: \(today)")
        dayChanged.emit(today)
    }
}
