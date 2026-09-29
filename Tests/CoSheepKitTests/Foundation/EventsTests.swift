import Testing
@testable import CoSheepKit

// Ex-events.test.ts
@Suite("flock event bus")
struct EventsTests {
    @Test func deliversPayloadToSubscriber() {
        let bus = FlockBus()
        var seen: [String] = []
        let off = bus.on(.sheepPetted) { e in
            if case .sheepPetted(let id) = e { seen.append(id) }
        }
        bus.emit(.sheepPetted(id: "good_colleague"))
        off()
        #expect(seen == ["good_colleague"])
    }

    @Test func unsubscribeStopsDelivery() {
        let bus = FlockBus()
        var calls = 0
        let off = bus.on(.sheepPetted) { _ in calls += 1 }
        off()
        bus.emit(.sheepPetted(id: "main"))
        #expect(calls == 0)
    }

    @Test func throwingHandlerDoesNotBreakOthers() {
        struct Boom: Error {}
        let bus = FlockBus()
        var seen: [String] = []
        let offA = bus.on(.appSwitched) { _ in throw Boom() }
        let offB = bus.on(.appSwitched) { e in
            if case .appSwitched(let s) = e { seen.append(s.app) }
        }
        bus.emit(.appSwitched(AppSwitch(app: "Xcode", previousApp: nil, previousDurationMs: 0)))
        offA()
        offB()
        #expect(seen == ["Xcode"])
    }
}
