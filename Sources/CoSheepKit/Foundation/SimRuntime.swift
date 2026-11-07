import Foundation

/// `Date.now()` / `performance.now()` replacements. Overridable in tests.
enum SimClock {
    /// Wall-clock epoch milliseconds (ex-`Date.now()`).
    static var nowSource: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    /// Monotonic milliseconds (ex-`performance.now()`). System uptime: it
    /// stops while the Mac sleeps.
    static var perfSource: () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }
    /// Monotonic milliseconds that keep counting while the Mac sleeps
    /// (`CLOCK_MONOTONIC` on Darwin), for TTLs that must age across sleep.
    static var continuousSource: () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 }
    /// The zone "local" means for days and hours. Tests pin it.
    static var timeZone: TimeZone = .autoupdatingCurrent

    static func nowMs() -> Double { nowSource() }
    static func perfMs() -> Double { perfSource() }
    static func continuousMs() -> Double { continuousSource() }

    /// A Gregorian calendar in `timeZone`.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Local hour 0–23 (ex-`new Date().getHours()`).
    static func hour() -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: nowMs() / 1000))
    }
}

/// `Math.random()` replacement. Overridable/seedable in tests.
enum SimRandom {
    static var source: () -> Double = { Double.random(in: 0..<1) }

    /// Uniform in [0, 1).
    static func next() -> Double { source() }

    /// `Math.floor(Math.random() * n)`.
    static func int(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        return min(n - 1, Int(next() * Double(n)))
    }

    /// `arr[Math.floor(Math.random() * arr.length)]`.
    static func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[int(items.count)]
    }

    /// Deterministic source for tests (SplitMix64).
    static func seeded(_ seed: UInt64) -> () -> Double {
        var state = seed
        return {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

/// Cancellable handle for `SimTimers` (ex-setTimeout/setInterval ids).
final class TimerToken {
    fileprivate var timer: Timer?
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
        timer?.invalidate()
        timer = nil
    }
}

/// `setTimeout` / `setInterval` replacements on the main run loop
/// (common modes, so they keep firing while a menu is open).
enum SimTimers {
    @discardableResult
    static func after(_ ms: Double, _ fn: @escaping @MainActor () -> Void) -> TimerToken {
        let token = TimerToken()
        // Strong capture: like setTimeout, the timer fires whether or not the
        // caller keeps the token. The cycle breaks when it fires or is cancelled.
        let t = Timer(timeInterval: max(0, ms) / 1000, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !token.isCancelled else { return }
                token.timer = nil
                fn()
            }
        }
        token.timer = t
        RunLoop.main.add(t, forMode: .common)
        return token
    }

    @discardableResult
    static func every(_ ms: Double, _ fn: @escaping @MainActor () -> Void) -> TimerToken {
        let token = TimerToken()
        // Like setInterval: runs until cancelled, token kept or not.
        let t = Timer(timeInterval: max(0.001, ms / 1000), repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !token.isCancelled else { return }
                fn()
            }
        }
        token.timer = t
        RunLoop.main.add(t, forMode: .common)
        return token
    }
}
