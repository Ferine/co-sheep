import Foundation
import Testing
@testable import CoSheepKit

@Suite("accessories", .serialized)
struct AccessoriesTests {
    private func ops(_ body: (Canvas) -> Void) -> Int {
        let c = Canvas()
        c.beginFrame()
        c.group("a") { body(c) }
        return c.groups[0].ops.count
    }

    @Test func registryHasTheTwentyOriginalAccessories() {
        let defs = getAccessoryDefs()
        #expect(defs.map(\.id) == [
            "party_hat", "crown", "sunglasses", "bow_tie", "flower", "scarf", "top_hat", "halo",
            "pirate_patch", "headphones", "monocle", "wizard_hat", "bandana", "mustache", "cape",
            "antenna", "chef_hat", "necklace", "bunny_ears", "easter_basket",
        ])
        #expect(Set(defs.map(\.id)).count == defs.count)
        let byId = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
        #expect(byId["crown"]?.name == "Crown")
        #expect(byId["pirate_patch"]?.name == "Eye Patch")
        #expect(byId["sunglasses"]?.category == .face)
        #expect(byId["scarf"]?.category == .neck)
        #expect(byId["top_hat"]?.category == .head)
        #expect(byId["easter_basket"]?.category == .neck)
    }

    @Test func everyAccessoryDrawsInEveryPose() {
        for def in getAccessoryDefs() {
            for facing in [true, false] {
                for size in [96.0, 110.0, 81.6] {
                    let n = ops { def.draw($0, 100, 200, size, facing, .idle) }
                    // The Easter basket is a calm-state accessory: it draws in idle too
                    #expect(n > 0, "\(def.id) drew nothing")
                }
            }
        }
    }

    @Test func compositeOverlayIsNilWithoutMatches() {
        #expect(createCompositeOverlay([]) == nil)
        #expect(createCompositeOverlay(["nope", "also_nope"]) == nil)
    }

    @Test func compositeOverlayDrawsSelectedAccessoriesInRegistryOrder() throws {
        let overlay = try #require(createCompositeOverlay(["crown", "party_hat"]))
        let c = Canvas()
        c.beginFrame()
        c.group("a") { overlay(c, 100, 200, 96, true, .idle) }
        let both = c.groups[0].ops.count

        let party = ops { getAccessoryDefs()[0].draw($0, 100, 200, 96, true, .idle) }
        let crown = ops { getAccessoryDefs()[1].draw($0, 100, 200, 96, true, .idle) }
        #expect(both == party + crown)

        // Registry order (party_hat first), not id order
        let fillFirst = c.groups[0].ops.compactMap { op -> Paint? in
            if case .fill(_, let paint, _) = op.kind { return paint }
            return nil
        }.first
        #expect(fillFirst == .color(try #require(CSSColor.parse("#e94560"))))
    }

    @Test func easterBasketOnlyShowsInCalmStates() {
        let calm: [SheepState] = [.idle, .sit, .idleSleep, .idleCampfire, .idleCounting, .idleEggPainting, .sleep]
        for state in SheepState.allCases {
            let n = ops { drawEasterBasket($0, 100, 200, 96, true, state) }
            #expect((n > 0) == calm.contains(state), "state \(state.rawValue)")
        }
    }

    @Test func easterBasketMovingStatesNeedAllowMoving() {
        #expect(ops { drawEasterBasket($0, 100, 200, 96, true, .walk) } == 0)
        #expect(ops { drawEasterBasket($0, 100, 200, 96, true, .walk, EasterBasketOptions(allowMoving: true)) } > 0)
        #expect(ops { drawEasterBasket($0, 100, 200, 96, true, .bounce, EasterBasketOptions(allowMoving: true)) } > 0)
        // allowMoving does not unlock other states
        #expect(ops { drawEasterBasket($0, 100, 200, 96, true, .zoom, EasterBasketOptions(allowMoving: true)) } == 0)
    }

    @Test func easterBasketEggCountIsRoundedAndClamped() {
        func eggs(_ n: Double?) -> Int {
            ops { drawEasterBasket($0, 100, 200, 96, true, .idle, EasterBasketOptions(eggCount: n)) }
        }
        let none = eggs(0)
        #expect(eggs(nil) == none + 3) // default 3
        #expect(eggs(5) == none + 5)
        #expect(eggs(99) == none + 5) // clamped
        #expect(eggs(-4) == none) // clamped
        #expect(eggs(2.5) == none + 3) // Math.round: half rounds up
        #expect(eggs(2.4) == none + 2)
        #expect(ops { drawEasterBasket($0, 100, 200, 96, true, .idle, EasterBasketOptions(eggCount: 4)) } == none + 4)
    }

    @Test func easterBasketSitsOnTheFacingSide() {
        func centerX(facing: Bool) -> Double {
            let c = Canvas()
            c.beginFrame()
            c.group("a") { drawEasterBasket(c, 100, 200, 96, facing, .idle) }
            return c.groups[0].bounds.midX
        }
        #expect(centerX(facing: true) > centerX(facing: false))
    }

    @Test func antennaBobsWithTheClock() {
        let saved = SimClock.nowSource
        defer { SimClock.nowSource = saved }
        let antenna = getAccessoryDefs().first { $0.id == "antenna" }!
        func bobbleY(at ms: Double) -> Double {
            SimClock.nowSource = { ms }
            let c = Canvas()
            c.beginFrame()
            c.group("a") { antenna.draw(c, 100, 200, 96, true, .idle) }
            return c.groups[0].bounds.minY
        }
        #expect(bobbleY(at: 0) != bobbleY(at: 500 * .pi / 2))
    }
}
