import Foundation
import Testing
@testable import CoSheepKit

/// Run the update loop until the parachute descent settles
private func settle(_ sheep: Sheep) {
    var i = 0
    while i < 5000 && sheep.state == .parachute {
        sheep.update(16)
        i += 1
    }
}

@Suite("Sheep agent-herd seams")
struct SheepHerdSeamTests {
    @Test func idleOverrideSteersTheNextStateWhenIdleEnds() {
        let sheep = Sheep(1512, 982, "lamb:a")
        settle(sheep)
        #expect(sheep.state == .idle)
        var asked = 0
        sheep.idleOverride = {
            asked += 1
            return (.sleep, 9000)
        }
        // Idle lasts ≤ 5 s after landing; run past it.
        for _ in 0..<400 { sheep.update(16) }
        #expect(asked >= 1)
        #expect(sheep.state == .sleep)
        #expect(sheep.stateDuration == 9000)
    }

    @Test func nilOverrideFallsBackToNormalWandering() {
        let sheep = Sheep(1512, 982, "lamb:a")
        settle(sheep)
        sheep.idleOverride = { nil }
        for _ in 0..<400 { sheep.update(16) }
        #expect(sheep.state != .leaving)
        #expect(sheep.state != .parachute)
    }

    @Test func redirectSwitchesOnlyFromCalmStates() {
        let sheep = Sheep(1512, 982, "lamb:a")
        // Still parachuting: physics plays out first.
        #expect(sheep.redirect(.sit, 5000) == false)
        #expect(sheep.state == .parachute)

        settle(sheep)
        #expect(sheep.redirect(.sit, 5000))
        #expect(sheep.state == .sit)

        sheep.startListening()
        #expect(sheep.redirect(.sleep, 5000) == false)
        sheep.stopListening()
    }

    @Test func leavingTrotsToTheNearestEdgeAndOffScreen() {
        let sheep = Sheep(1512, 982, "lamb:a", nil, 1300)
        settle(sheep)
        #expect(sheep.redirect(.leaving, 0))
        #expect(sheep.state == .leaving)
        #expect(sheep.facingRight) // nearer the right edge
        var i = 0
        while !sheep.hasLeft && i < 2000 {
            sheep.update(16)
            i += 1
        }
        #expect(sheep.hasLeft)
        #expect(sheep.x > 1512)
    }

    @Test func leavingIsNotClampedOrPulledBackByReground() {
        let sheep = Sheep(1512, 982, "lamb:a", nil, 20)
        settle(sheep)
        sheep.startLeaving()
        #expect(!sheep.facingRight)
        for _ in 0..<60 { sheep.update(16) }
        sheep.x = -40
        sheep.reground()
        #expect(sheep.x == -40)
        #expect(sheep.state == .leaving)
    }

    @Test func leavingDropsOffAWindowAndKeepsGoing() {
        let sheep = Sheep(1512, 982, "lamb:a", nil, 1100)
        sheep.platforms = [WindowPlatform(x: 900, y: 400, w: 500, h: 400)]
        settle(sheep)
        #expect(sheep.currentPlatform != nil)
        sheep.platforms = [WindowPlatform(x: 900, y: 400, w: 500, h: 400)]
        sheep.startLeaving()
        var i = 0
        while !sheep.hasLeft && i < 3000 {
            sheep.update(16)
            i += 1
        }
        #expect(sheep.hasLeft)
        #expect(sheep.state == .leaving)
        #expect(sheep.y == sheep.groundY)
    }

    @Test func idleOverrideCanStartLeaving() {
        let sheep = Sheep(1512, 982, "lamb:a", nil, 100)
        settle(sheep)
        sheep.idleOverride = { (.leaving, 0) }
        for _ in 0..<400 { sheep.update(16) }
        #expect(sheep.state == .leaving)
        #expect(!sheep.facingRight)
    }
}
