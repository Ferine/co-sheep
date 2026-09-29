import Foundation
import Testing
@testable import CoSheepKit

private func pair(_ mutate: (inout PairInput) -> Void = { _ in }) -> PairInput {
    var p = PairInput(
        idA: "friend_a",
        idB: "friend_b",
        affinity: 0,
        moodA: "happy",
        moodB: "happy",
        state: .neutral,
        msInState: DRAMA.MIN_DWELL_MS + 1,
        pettingGap: 0,
        spark: 0.99 // never fires random spark unless a test lowers it
    )
    mutate(&p)
    return p
}

// Ex-drama.test.ts
@Suite("pairKey")
struct PairKeyTests {
    @Test func isOrderIndependent() {
        #expect(pairKey("b", "a") == "a|b")
        #expect(pairKey("a", "b") == "a|b")
    }
}

@Suite("evaluatePair transitions")
struct EvaluatePairTests {
    private func expectTransition(_ t: DramaTransition?, from: RelationshipState, to: RelationshipState,
                                  cause: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(t?.from == from, sourceLocation: sourceLocation)
        #expect(t?.to == to, sourceLocation: sourceLocation)
        if let cause { #expect(t?.cause == cause, sourceLocation: sourceLocation) }
    }

    @Test func neutralToWarmOnHighAffinity() {
        let t = evaluatePair(pair { $0.affinity = DRAMA.WARM_ENTER })
        expectTransition(t, from: .neutral, to: .warm)
    }

    @Test func neutralToTensionOnLowAffinity() {
        let t = evaluatePair(pair { $0.affinity = DRAMA.TENSION_ENTER })
        expectTransition(t, from: .neutral, to: .tension)
    }

    @Test func neutralToTensionOnJealousy() {
        let t = evaluatePair(pair { p in
            p.affinity = 2
            p.pettingGap = DRAMA.JEALOUSY_GAP
        })
        expectTransition(t, from: .neutral, to: .tension, cause: "jealousy")
    }

    @Test func respectsMinimumDwellTime() {
        let t = evaluatePair(pair {
            $0.affinity = DRAMA.WARM_ENTER
            $0.msInState = 1000
        })
        #expect(t == nil)
    }

    @Test func warmToInseparableNeedsAffinityAndLongDwell() {
        let notYet = evaluatePair(pair {
            $0.state = .warm
            $0.affinity = DRAMA.INSEP_ENTER
            $0.msInState = DRAMA.MIN_DWELL_MS + 1
        })
        #expect(notYet == nil)
        let now = evaluatePair(pair {
            $0.state = .warm
            $0.affinity = DRAMA.INSEP_ENTER
            $0.msInState = DRAMA.INSEP_DWELL_MS + 1
        })
        expectTransition(now, from: .warm, to: .inseparable)
    }

    @Test func warmToNeutralBelowExitThreshold() {
        let stays = evaluatePair(pair {
            $0.state = .warm
            $0.affinity = DRAMA.WARM_EXIT
        })
        #expect(stays == nil)
        let cools = evaluatePair(pair {
            $0.state = .warm
            $0.affinity = DRAMA.WARM_EXIT - 1
        })
        expectTransition(cools, from: .warm, to: .neutral)
    }

    @Test func tensionToFeudWhenAGrumpHoldsAGrudgeLongEnough() {
        let t = evaluatePair(pair {
            $0.state = .tension
            $0.affinity = -4
            $0.moodA = "grumpy"
            $0.msInState = DRAMA.FEUD_DWELL_MS + 1
        })
        expectTransition(t, from: .tension, to: .feud)
    }

    @Test func tensionToFeudOnRandomSpark() {
        let t = evaluatePair(pair {
            $0.state = .tension
            $0.affinity = -4
            $0.spark = 0
        })
        expectTransition(t, from: .tension, to: .feud, cause: "spark")
    }

    @Test func tensionToNeutralWhenCooledOff() {
        let t = evaluatePair(pair {
            $0.state = .tension
            $0.affinity = DRAMA.TENSION_EXIT
        })
        expectTransition(t, from: .tension, to: .neutral)
    }

    @Test func feudToReconcilingAfterTiringOut() {
        let t = evaluatePair(pair {
            $0.state = .feud
            $0.affinity = -5
            $0.msInState = DRAMA.FEUD_TIREOUT_MS + 1
        })
        expectTransition(t, from: .feud, to: .reconciling)
    }

    @Test func reconcilingToWarmQuickly() {
        let t = evaluatePair(pair {
            $0.state = .reconciling
            $0.affinity = 0
            $0.msInState = DRAMA.RECONCILE_MS + 1
        })
        expectTransition(t, from: .reconciling, to: .warm)
    }

    // Additional coverage for branches the vitest file doesn't reach.

    @Test func causesMatchTheOriginalStrings() {
        #expect(evaluatePair(pair { $0.affinity = DRAMA.WARM_ENTER })?.cause == "growing affinity")
        #expect(evaluatePair(pair { $0.affinity = DRAMA.TENSION_ENTER })?.cause == "low affinity")
        #expect(evaluatePair(pair { $0.state = .warm; $0.affinity = 0 })?.cause == "drifted apart")
        #expect(evaluatePair(pair {
            $0.state = .warm; $0.affinity = DRAMA.INSEP_ENTER; $0.msInState = DRAMA.INSEP_DWELL_MS
        })?.cause == "best friends now")
        #expect(evaluatePair(pair { $0.state = .inseparable; $0.affinity = DRAMA.INSEP_EXIT - 1 })?.cause == "cooled slightly")
        #expect(evaluatePair(pair { $0.state = .tension; $0.affinity = DRAMA.TENSION_EXIT })?.cause == "cooled off")
        #expect(evaluatePair(pair {
            $0.state = .tension; $0.affinity = -4; $0.moodB = "grumpy"; $0.msInState = DRAMA.FEUD_DWELL_MS
        })?.cause == "grudge")
        #expect(evaluatePair(pair { $0.state = .feud; $0.msInState = DRAMA.FEUD_TIREOUT_MS })?.cause == "tired of fighting")
        #expect(evaluatePair(pair { $0.state = .reconciling; $0.msInState = DRAMA.RECONCILE_MS })?.cause == "made up")
    }

    @Test func tensionStaysWhenStillJealousEvenIfAffinityRecovered() {
        // affinity >= TENSION_EXIT but the petting gap is still large -> no cool-off.
        let t = evaluatePair(pair {
            $0.state = .tension
            $0.affinity = DRAMA.TENSION_EXIT
            $0.pettingGap = DRAMA.JEALOUSY_GAP
        })
        #expect(t == nil)
    }

    @Test func feudAndReconcilingWaitOutTheirTimers() {
        #expect(evaluatePair(pair { $0.state = .feud; $0.msInState = DRAMA.FEUD_TIREOUT_MS - 1 }) == nil)
        #expect(evaluatePair(pair { $0.state = .reconciling; $0.msInState = DRAMA.RECONCILE_MS - 1 }) == nil)
    }

    @Test func transitionCarriesPairIds() {
        let t = evaluatePair(pair { $0.affinity = DRAMA.WARM_ENTER })
        #expect(t?.idA == "friend_a" && t?.idB == "friend_b")
    }

    @Test func relationshipStateRawValues() {
        #expect(RelationshipState.allCases.map(\.rawValue)
            == ["neutral", "warm", "inseparable", "tension", "feud", "reconciling"])
    }
}

@Suite("evaluateDrama")
struct EvaluateDramaTests {
    @Test func returnsOnlyPairsThatTransition() {
        let out = evaluateDrama([
            pair { $0.affinity = DRAMA.WARM_ENTER },
            pair { $0.idA = "x"; $0.idB = "y"; $0.affinity = 0 },
        ])
        #expect(out.count == 1)
        #expect(out[0].to == .warm)
    }
}

@Suite("blocksGroupActivity")
struct BlocksGroupActivityTests {
    @Test func onlyFeudBlocks() {
        #expect(blocksGroupActivity(.feud) == true)
        #expect(blocksGroupActivity(.tension) == false)
        #expect(blocksGroupActivity(.warm) == false)
    }
}

@Suite("pruneCharacterFromPairs")
struct PruneCharacterFromPairsTests {
    struct Rec: Equatable {
        var state: String
        var since: Int
    }

    private let pairs: [String: Rec] = [
        pairKey("main", "friend_1"): Rec(state: "feud", since: 100),
        pairKey("friend_1", "friend_2"): Rec(state: "warm", since: 200),
        pairKey("main", "friend_2"): Rec(state: "neutral", since: 300),
    ]

    @Test func removesEveryPairInvolvingTheDepartedCharacter() {
        let out = pruneCharacterFromPairs(pairs, "friend_1")
        #expect(Array(out.keys) == [pairKey("main", "friend_2")])
        #expect(out[pairKey("main", "friend_2")] == Rec(state: "neutral", since: 300))
    }

    @Test func returnsPairsUnchangedForAnUnknownId() {
        #expect(pruneCharacterFromPairs(pairs, "friend_99") == pairs)
    }

    @Test func doesNotPruneOnPartialIdMatches() {
        let p = [pairKey("friend_1", "friend_12"): Rec(state: "warm", since: 1)]
        #expect(pruneCharacterFromPairs(p, "friend_1").isEmpty)
        #expect(pruneCharacterFromPairs(p, "friend_12").isEmpty)
        #expect(pruneCharacterFromPairs(p, "friend_").count == 1)
    }
}

// Ex-drama-scripts.ts (no vitest file; behavior tests for the port).
@Suite("drama scripts")
struct DramaScriptsTests {
    @Test func everyKindHasScriptsAndPlaceholdersResolve() {
        for kind in DramaScriptKind.allCases {
            for _ in 0..<20 {
                let script = pickDramaScript(kind, "id_a", "id_b", "id_m")
                #expect(!script.isEmpty)
                for line in script {
                    #expect(!line.speakerId.hasPrefix("$"), "unresolved \(line.speakerId) in \(kind)")
                    #expect(["id_a", "id_b", "id_m"].contains(line.speakerId))
                }
            }
        }
    }

    @Test func mediatorDefaultsToIdAWhenAbsent() {
        let saved = SimRandom.source
        defer { SimRandom.source = saved }
        SimRandom.source = { 0 } // first mediation template starts with the mediator
        let script = pickDramaScript(.mediation, "id_a", "id_b")
        #expect(script[0].speakerId == "id_a")
        #expect(script[1].speakerId == "id_a") // $A
        #expect(script[2].speakerId == "id_b") // $B
    }

    @Test func picksTemplateByRandomIndexAndKeepsLineData() {
        let saved = SimRandom.source
        defer { SimRandom.source = saved }
        SimRandom.source = { 0 }
        let first = pickDramaScript(.feudStart, "a", "b")
        #expect(first.map(\.text) == ["You know what? No. I'm done.", "DONE? *I'M* done!", "Fine!", "FINE!"])
        #expect(first.map(\.speakerId) == ["a", "b", "a", "b"])
        #expect(first.map(\.duration) == [3500, 3000, 2000, 2000])
        #expect(first.map(\.delay) == [0, 600, 500, 400])
        #expect(first.map(\.animation) == [.headshake, .vibrate, nil, nil])

        SimRandom.source = { 0.999 }
        let last = pickDramaScript(.feudStart, "a", "b")
        #expect(last.map(\.text) == [
            "I saw what you did at the campfire.",
            "Oh, we're doing THIS now?",
            "We are ABSOLUTELY doing this now.",
        ])
    }

    @Test func scriptCountsMatchTheReference() {
        // 2 feud_start, 3 feud_snipe, 2 jealousy, 2 mediation, 1 reconciliation, 2 inseparable
        var seen: [DramaScriptKind: Set<String>] = [:]
        let saved = SimRandom.source
        defer { SimRandom.source = saved }
        for step in 0..<100 {
            let r = Double(step) / 100
            SimRandom.source = { r }
            for kind in DramaScriptKind.allCases {
                seen[kind, default: []].insert(pickDramaScript(kind, "a", "b", "m")[0].text)
            }
        }
        #expect(seen[.feudStart]?.count == 2)
        #expect(seen[.feudSnipe]?.count == 3)
        #expect(seen[.jealousy]?.count == 2)
        #expect(seen[.mediation]?.count == 2)
        #expect(seen[.reconciliation]?.count == 1)
        #expect(seen[.inseparable]?.count == 2)
    }

    @Test func rawValuesMatchTheReferenceStrings() {
        #expect(DramaScriptKind.allCases.map(\.rawValue)
            == ["feud_start", "feud_snipe", "jealousy", "mediation", "reconciliation", "inseparable"])
    }
}
