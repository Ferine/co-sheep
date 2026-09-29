import Foundation

// Ex-app_watch.rs (the loop half; the frontmost lookup lives in WindowList).
// Polls the frontmost app and publishes `app-switched` on change. The overlay
// bridges the event onto the flock bus.

final class AppWatch {
    /// The Rust loop slept 5 s between polls (sleep first, then check).
    static let pollIntervalSeconds = 5.0

    private let ownPid: Int32
    private let pollInterval: Double
    private let events: AppEvents
    private let frontmostAppName: @Sendable (Int32) -> String?
    private let now: () -> Double

    private var current: String?
    private var since: Double
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - pollInterval: seconds between polls.
    ///   - frontmostAppName: the blocking lookup, run off the main thread
    ///     (ex-`spawn_blocking`). Injected in tests.
    ///   - now: monotonic milliseconds (ex-`Instant`).
    init(
        ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
        pollInterval: Double = AppWatch.pollIntervalSeconds,
        events: AppEvents = .shared,
        frontmostAppName: @escaping @Sendable (Int32) -> String? = { WindowList.frontmostAppName(ownPid: $0) },
        now: @escaping () -> Double = { SimClock.perfMs() }
    ) {
        self.ownPid = ownPid
        self.pollInterval = pollInterval
        self.events = events
        self.frontmostAppName = frontmostAppName
        self.now = now
        self.since = now()
    }

    var isRunning: Bool { loop != nil }

    /// ex-`app_watch_loop`. Starting twice is a no-op.
    func start() {
        guard loop == nil else { return }
        since = now()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.pollOnce()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One loop iteration: look up the frontmost app off-main, then bookkeep.
    /// An unusable lookup (nil) skips the iteration, like the Rust `continue`.
    func pollOnce() async {
        guard let front = await Self.lookup(frontmostAppName, ownPid: ownPid) else { return }
        handleFrontmost(front)
    }

    /// Change detection and duration bookkeeping. Emits `app-switched` when the
    /// frontmost app differs from the last one seen. The first observation has
    /// no previous app and reports a previous duration of 0.
    func handleFrontmost(_ front: String) {
        guard current != front else { return }
        let previousDurationMs = (now() - since).rounded(.down)
        events.appSwitched.emit(AppSwitch(
            app: front,
            previousApp: current,
            previousDurationMs: current != nil ? previousDurationMs : 0))
        Log.info("watch", "App switched to: \(front)")
        current = front
        since = now()
    }

    @concurrent
    private static func lookup(_ fn: @Sendable (Int32) -> String?, ownPid: Int32) async -> String? {
        fn(ownPid)
    }
}
