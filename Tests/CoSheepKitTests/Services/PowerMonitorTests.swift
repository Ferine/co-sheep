import AppKit
import Foundation
import Testing
@testable import CoSheepKit

@Suite("power monitor", .serialized)
struct PowerMonitorTests {
    /// A monitor on private centers, its published changes, and a scriptable probe.
    private final class Rig {
        let events = AppEvents()
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var probe: SessionProbe?
        var changes: [PowerChange] = []
        lazy var monitor = PowerMonitor(
            events: events, workspaceCenter: workspace, distributedCenter: distributed,
            probe: { [unowned self] in self.probe })
        private var unsubscribe: (() -> Void)?

        init() {
            unsubscribe = events.power.on { [unowned self] in self.changes.append($0) }
        }

        func post(_ name: Notification.Name, distributed: Bool = false) {
            (distributed ? self.distributed : workspace).post(name: name, object: nil)
        }
    }

    @Test func presenceIsAwayWhileAnySourceSaysSo() {
        var p = Presence()
        #expect(!p.isAway)
        p.apply(.locked)
        p.apply(.willSleep)
        #expect(p.isAway)
        p.apply(.didWake)
        #expect(p.isAway) // still locked
        p.apply(.unlocked)
        #expect(!p.isAway)
        for (on, off) in [(PowerEvent.screensDidSleep, PowerEvent.screensDidWake),
                          (.screensaverStarted, .screensaverStopped), (.sessionResigned, .sessionActive)] {
            p.apply(on)
            #expect(p.isAway)
            p.apply(off)
            #expect(!p.isAway)
        }
    }

    @Test func publishesWorkspaceAndDistributedNotifications() {
        let rig = Rig()
        rig.monitor.start()
        defer { rig.monitor.stop() }

        rig.post(NSWorkspace.willSleepNotification)
        rig.post(Notification.Name("com.apple.screenIsLocked"), distributed: true)
        rig.post(NSWorkspace.didWakeNotification)
        rig.post(Notification.Name("com.apple.screenIsUnlocked"), distributed: true)

        #expect(rig.changes.map(\.event) == [.willSleep, .locked, .didWake, .unlocked])
        #expect(rig.changes.map(\.presence.isAway) == [true, true, true, false])
    }

    @Test func everyMappedNameIsObserved() {
        let rig = Rig()
        rig.monitor.start()
        defer { rig.monitor.stop() }
        for (name, _) in PowerMonitor.workspaceEvents { rig.post(name) }
        for (name, _) in PowerMonitor.distributedEvents { rig.post(name, distributed: true) }
        #expect(rig.changes.map(\.event)
            == PowerMonitor.workspaceEvents.map(\.1) + PowerMonitor.distributedEvents.map(\.1))
    }

    @Test func startTwiceObservesOnceAndStopDetaches() {
        let rig = Rig()
        rig.monitor.start()
        rig.monitor.start()
        rig.post(NSWorkspace.screensDidSleepNotification)
        #expect(rig.changes.count == 1)
        rig.monitor.stop()
        #expect(!rig.monitor.isRunning)
        rig.post(NSWorkspace.screensDidWakeNotification)
        #expect(rig.changes.count == 1)
    }

    @Test func aMissedUnlockIsRecoveredFromTheSessionOnWake() {
        let rig = Rig()
        rig.monitor.start()
        defer { rig.monitor.stop() }
        rig.post(Notification.Name("com.apple.screenIsLocked"), distributed: true)
        #expect(rig.monitor.presence.locked)

        // The unlock notification never arrives; the session says unlocked.
        rig.probe = SessionProbe(locked: false, onConsole: true)
        rig.post(NSWorkspace.screensDidWakeNotification)
        #expect(!rig.monitor.presence.isAway)
        #expect(rig.changes.last?.presence.isAway == false)
    }

    @Test func startTakesTheCurrentLockState() {
        let rig = Rig()
        rig.probe = SessionProbe(locked: true, onConsole: true)
        rig.monitor.start()
        defer { rig.monitor.stop() }
        #expect(rig.monitor.presence.locked)
        #expect(rig.changes.isEmpty) // nothing happened, so nothing is published
    }
}

@Suite("day clock", .serialized)
struct DayClockTests {
    @Test func emitsOncePerNewLocalDay() {
        let savedNow = SimClock.nowSource, savedZone = SimClock.timeZone
        defer { SimClock.nowSource = savedNow; SimClock.timeZone = savedZone }
        SimClock.timeZone = TimeZone(identifier: "Europe/Oslo")!
        var now = 1_790_683_200_000.0 // 2026-09-29T12:00Z, 14:00 in Oslo
        SimClock.nowSource = { now }

        let clock = DayClock(center: NotificationCenter())
        var days: [String] = []
        let unsubscribe = clock.dayChanged.on { days.append($0) }
        defer { unsubscribe() }
        #expect(clock.current == "2026-09-29")

        clock.check()
        now += 9 * 3600 * 1000 // 21:00Z, 23:00 in Oslo: still the 29th
        clock.check()
        #expect(days.isEmpty)
        now += 2 * 3600 * 1000 // 23:00Z: already the 30th in Oslo
        clock.check()
        clock.check()
        #expect(days == ["2026-09-30"])
    }

    @Test func theDayChangedNotificationTriggersACheck() {
        let savedNow = SimClock.nowSource
        defer { SimClock.nowSource = savedNow }
        var now = 1_790_683_200_000.0
        SimClock.nowSource = { now }
        let center = NotificationCenter()
        let clock = DayClock(center: center)
        var days: [String] = []
        let unsubscribe = clock.dayChanged.on { days.append($0) }
        defer { unsubscribe() }
        clock.start()
        defer { clock.stop() }

        now += 2 * 24 * 3600 * 1000
        center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(days.count == 1)
    }
}
