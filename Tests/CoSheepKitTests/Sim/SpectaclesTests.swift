import Foundation
import Testing
@testable import CoSheepKit

private let DAY: Double = 24 * 3600 * 1000

private func fresh() -> SpectacleSchedulerState {
    SpectacleSchedulerState(lastFiredMs: 0, lastByType: [:])
}

private func firedAt(_ lastFiredMs: Double) -> SpectacleSchedulerState {
    var s = fresh()
    s.lastFiredMs = lastFiredMs
    return s
}

// Ex-spectacles.test.ts
@Suite("pickRandomSpectacle")
struct PickRandomSpectacleTests {
    @Test func neverFiresWithinMinGapOfTheLastSpectacle() {
        let picked = pickRandomSpectacle(SchedulerInput(
            state: firedAt(100 * DAY),
            nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS - 1,
            isNight: false,
            rand: 0 // would otherwise always fire
        ))
        #expect(picked == nil)
    }

    @Test func neverFiresAtNight() {
        let picked = pickRandomSpectacle(SchedulerInput(
            state: fresh(), nowMs: 100 * DAY, isNight: true, rand: 0))
        #expect(picked == nil)
    }

    @Test func firesOnALuckyRollAfterTheGap() {
        let picked = pickRandomSpectacle(SchedulerInput(
            state: firedAt(100 * DAY),
            nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
            isNight: false,
            rand: 0
        ))
        #expect(picked != nil)
    }

    @Test func doesNotFireOnAnUnluckyRollBeforeThePityTimer() {
        let picked = pickRandomSpectacle(SchedulerInput(
            state: firedAt(100 * DAY),
            nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
            isNight: false,
            rand: 0.99
        ))
        #expect(picked == nil)
    }

    @Test func pityTimerForcesASpectacleEvenOnAnUnluckyRoll() {
        let picked = pickRandomSpectacle(SchedulerInput(
            state: firedAt(100 * DAY),
            nowMs: 100 * DAY + SPECTACLE.PITY_MS + 1,
            isNight: false,
            rand: 0.99
        ))
        #expect(picked != nil)
    }

    @Test func respectsThePerTypeCooldown() {
        // Exhaust every type's cooldown except one; the pick must be that one.
        let nowMs = 100 * DAY
        var state = fresh()
        state = markFired(state, .wolf, nowMs - 1)
        state = markFired(state, .ufo, nowMs - 1)
        state = markFired(state, .merchant, nowMs - 1)
        state = markFired(state, .shearing, nowMs - 1)
        state.lastFiredMs = nowMs - SPECTACLE.MIN_GAP_MS - 1
        let picked = pickRandomSpectacle(SchedulerInput(state: state, nowMs: nowMs, isNight: false, rand: 0))
        #expect(picked == .balloon)
    }

    @Test func returnsNullWhenEveryTypeIsCoolingDown() {
        let nowMs = 100 * DAY
        var state = fresh()
        for t in [SpectacleType.wolf, .ufo, .merchant, .balloon, .shearing] {
            state = markFired(state, t, nowMs - 1)
        }
        state.lastFiredMs = nowMs - SPECTACLE.PITY_MS - 1
        #expect(pickRandomSpectacle(SchedulerInput(state: state, nowMs: nowMs, isNight: false, rand: 0)) == nil)
    }

    @Test func weightedPickSpansTheTableAcrossTheSurvivingRandRange() {
        let state = firedAt(100 * DAY)
        let nowMs = 100 * DAY + SPECTACLE.MIN_GAP_MS + 1
        // rand just under the gate → renormalized near 1 → last table entry
        let high = pickRandomSpectacle(SchedulerInput(
            state: state, nowMs: nowMs, isNight: false, rand: SPECTACLE.TICK_CHANCE * 0.999))
        #expect(high == .shearing)
        // rand near 0 → first table entry
        let low = pickRandomSpectacle(SchedulerInput(
            state: state, nowMs: nowMs, isNight: false, rand: 0.0000001))
        #expect(low == .wolf)
    }

    @Test func midRangeSurvivingRandPicksAMiddleTableEntry() {
        let state = firedAt(100 * DAY)
        let nowMs = 100 * DAY + SPECTACLE.MIN_GAP_MS + 1
        // renormalized ≈ 0.45 → roll ≈ 4.5 of 10 → second entry (ufo: wolf covers [0,3))
        let mid = pickRandomSpectacle(SchedulerInput(
            state: state, nowMs: nowMs, isNight: false, rand: SPECTACLE.TICK_CHANCE * 0.45))
        #expect(mid == .ufo)
    }

    // Additional coverage.

    @Test func neverPicksTheDramaTriggeredTypes() {
        let state = firedAt(0)
        let nowMs = 100 * DAY
        for step in 0..<200 {
            let picked = pickRandomSpectacle(SchedulerInput(
                state: state, nowMs: nowMs, isNight: false, rand: Double(step) / 200))
            #expect(picked != .showdown && picked != .feast)
        }
    }

    @Test func tableWeightsAre3_2_2_2_1() {
        // Sweep the surviving rand range and count picks per type at 1000 steps of a 10-wide roll.
        let state = firedAt(100 * DAY)
        let nowMs = 100 * DAY + SPECTACLE.MIN_GAP_MS + 1
        var counts: [SpectacleType: Int] = [:]
        for step in 0..<1000 {
            let rand = SPECTACLE.TICK_CHANCE * (Double(step) + 0.5) / 1000
            let picked = pickRandomSpectacle(SchedulerInput(state: state, nowMs: nowMs, isNight: false, rand: rand))
            counts[picked!, default: 0] += 1
        }
        #expect(counts[.wolf] == 300)
        #expect(counts[.ufo] == 200)
        #expect(counts[.merchant] == 200)
        #expect(counts[.balloon] == 200)
        #expect(counts[.shearing] == 100)
    }
}

@Suite("markFired")
struct MarkFiredTests {
    @Test func stampsBothTheGlobalAndPerTypeClocks() {
        let s = markFired(fresh(), .wolf, 123)
        #expect(s.lastFiredMs == 123)
        #expect(s.lastByType[.wolf] == 123)
    }

    @Test func keepsOtherTypesAndDoesNotMutateTheInput() {
        let a = markFired(fresh(), .wolf, 1)
        let b = markFired(a, .ufo, 2)
        #expect(b.lastByType == [.wolf: 1, .ufo: 2])
        #expect(a.lastByType == [.wolf: 1])
    }
}

@Suite("spectacle scheduler state json")
struct SpectacleStateJSONTests {
    @Test func encodesLastByTypeAsAPlainObject() throws {
        let s = SpectacleSchedulerState(lastFiredMs: 1700000000000, lastByType: [.wolf: 5, .ufo: 7])
        let data = try JSONEncoder().encode(s)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["lastFiredMs"] as? Double == 1700000000000)
        let by = try #require(obj["lastByType"] as? [String: Double])
        #expect(by == ["wolf": 5, "ufo": 7])
    }

    @Test func decodesTheTypeScriptShape() throws {
        let json = #"{"lastFiredMs": 1234, "lastByType": {"wolf": 1000, "showdown": 2, "bogus": 3}}"#
        let s = try JSONDecoder().decode(SpectacleSchedulerState.self, from: Data(json.utf8))
        #expect(s.lastFiredMs == 1234)
        #expect(s.lastByType == [.wolf: 1000, .showdown: 2]) // unknown type names are dropped
    }

    @Test func missingLastByTypeDecodesEmptyButMissingLastFiredMsFails() throws {
        let ok = try JSONDecoder().decode(SpectacleSchedulerState.self, from: Data(#"{"lastFiredMs": 9}"#.utf8))
        #expect(ok.lastByType.isEmpty)
        // `typeof s.lastFiredMs === "number"` guard in the TS loader → caller keeps its default.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SpectacleSchedulerState.self, from: Data(#"{"lastByType": {}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SpectacleSchedulerState.self, from: Data(#"{"lastFiredMs": "x"}"#.utf8))
        }
    }

    @Test func roundTrips() throws {
        let s = markFired(markFired(fresh(), .merchant, 10), .feast, 20)
        let back = try JSONDecoder().decode(SpectacleSchedulerState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
