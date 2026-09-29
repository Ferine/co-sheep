import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

// app_watch.rs had no Rust tests; these pin the bookkeeping and the loop.
@Suite("app watch")
struct AppWatchTests {
    private final class FakeClock {
        var ms = 0.0
    }

    /// Hands out scripted lookups (nil = "no usable answer"), repeating the last.
    private nonisolated final class Feed: Sendable {
        private let queue: Mutex<[String?]>
        private let count = Mutex(0)
        init(_ script: [String?]) { queue = Mutex(script) }
        var lookups: Int { count.withLock { $0 } }
        func next() -> String? {
            count.withLock { $0 += 1 }
            return queue.withLock { q in q.count > 1 ? q.removeFirst() : q.first ?? nil }
        }
    }

    private func makeWatch(
        events: AppEvents, clock: FakeClock = FakeClock(), interval: Double = AppWatch.pollIntervalSeconds,
        feed: Feed = Feed([nil])
    ) -> AppWatch {
        AppWatch(
            ownPid: 1, pollInterval: interval, events: events,
            frontmostAppName: { _ in feed.next() }, now: { clock.ms })
    }

    @Test func pollsEveryFiveSeconds() {
        #expect(AppWatch.pollIntervalSeconds == 5)
    }

    @Test func firstObservationHasNoPreviousAppAndZeroDuration() {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let clock = FakeClock()
        clock.ms = 90_000 // the watcher has been alive a while before the first app is seen
        let watch = makeWatch(events: events, clock: clock)
        clock.ms += 5_000

        watch.handleFrontmost("Safari")

        #expect(seen == [AppSwitch(app: "Safari", previousApp: nil, previousDurationMs: 0)])
    }

    @Test func switchReportsHowLongThePreviousAppWasFrontmost() {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let clock = FakeClock()
        let watch = makeWatch(events: events, clock: clock)

        watch.handleFrontmost("Safari")
        clock.ms += 3_700_000
        watch.handleFrontmost("Xcode")

        #expect(seen.count == 2)
        #expect(seen[1] == AppSwitch(app: "Xcode", previousApp: "Safari", previousDurationMs: 3_700_000))
    }

    @Test func sameAppAgainEmitsNothingAndKeepsTheClock() {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let clock = FakeClock()
        let watch = makeWatch(events: events, clock: clock)

        watch.handleFrontmost("Safari")
        clock.ms += 10_000
        watch.handleFrontmost("Safari")
        clock.ms += 10_000
        watch.handleFrontmost("Xcode")

        #expect(seen.count == 2)
        #expect(seen[1].previousDurationMs == 20_000) // measured from the first sighting
    }

    @Test func durationIsWholeMilliseconds() {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let clock = FakeClock()
        let watch = makeWatch(events: events, clock: clock)

        watch.handleFrontmost("A")
        clock.ms += 1500.9 // Rust's as_millis() floors
        watch.handleFrontmost("B")
        clock.ms += 2000
        watch.handleFrontmost("A")

        #expect(seen[1].previousDurationMs == 1500)
        #expect(seen[2] == AppSwitch(app: "A", previousApp: "B", previousDurationMs: 2000))
    }

    @Test func pollOnceFeedsTheLookupResultIntoTheBookkeeping() async {
        let events = AppEvents()
        var seen: [String] = []
        events.appSwitched.on { seen.append($0.app) }
        let watch = makeWatch(events: events, feed: Feed(["Safari", nil, "Safari", "Xcode"]))

        await watch.pollOnce()  // Safari
        await watch.pollOnce()  // nil: skipped, like the Rust `continue`
        await watch.pollOnce()  // Safari again: no change
        await watch.pollOnce()  // Xcode

        #expect(seen == ["Safari", "Xcode"])
    }

    @Test func aFailedLookupNeverEmitsOrResetsTheClock() async {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let clock = FakeClock()
        let watch = makeWatch(events: events, clock: clock, feed: Feed([nil]))
        watch.handleFrontmost("Safari")
        clock.ms += 5_000
        await watch.pollOnce() // lookup gives nil
        clock.ms += 5_000
        watch.handleFrontmost("Xcode")
        #expect(seen.map(\.app) == ["Safari", "Xcode"])
        #expect(seen[1].previousDurationMs == 10_000)
    }

    @Test func lookupRunsOffTheMainThread() async {
        let events = AppEvents()
        let onMain = Mutex<Bool?>(nil)
        let watch = AppWatch(
            ownPid: 1, events: events,
            frontmostAppName: { _ in
                onMain.withLock { $0 = Thread.isMainThread }
                return nil
            },
            now: { 0 })
        await watch.pollOnce()
        #expect(onMain.withLock { $0 } == false)
    }

    @Test func loopPollsUntilStopped() async throws {
        let events = AppEvents()
        var seen: [AppSwitch] = []
        events.appSwitched.on { seen.append($0) }
        let feed = Feed(["A", "A", nil, "B"])
        let watch = makeWatch(events: events, interval: 0.02, feed: feed)
        #expect(!watch.isRunning)

        watch.start()
        watch.start() // second start is a no-op
        #expect(watch.isRunning)

        let deadline = ContinuousClock.now + .seconds(5)
        while seen.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        watch.stop()
        #expect(!watch.isRunning)

        #expect(seen.map(\.app) == ["A", "B"])
        #expect(seen[0].previousApp == nil)
        #expect(seen[1].previousApp == "A")

        // Stopped means stopped: no more lookups.
        try await Task.sleep(for: .milliseconds(100))
        let after = feed.lookups
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.lookups == after)
    }

    @Test func sleepsBeforeTheFirstPoll() async throws {
        let events = AppEvents()
        let feed = Feed(["A"])
        let watch = makeWatch(events: events, interval: 1.0, feed: feed)
        watch.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.lookups == 0) // the Rust loop slept first, then checked
        watch.stop()
    }
}
