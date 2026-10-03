import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

@Suite("lamb wool and numbers", .serialized)
struct LambNumbersTests {
    @Test func woolLevelsFollowThePixtuoidTiers() {
        #expect(WoolMeter.level(forTokens: 0) == 0)
        #expect(WoolMeter.level(forTokens: 249_999) == 0)
        #expect(WoolMeter.level(forTokens: 250_000) == 1)
        #expect(WoolMeter.level(forTokens: 1_999_999) == 1)
        #expect(WoolMeter.level(forTokens: 2_000_000) == 2)
        #expect(WoolMeter.level(forTokens: 15_999_999) == 2)
        #expect(WoolMeter.level(forTokens: 16_000_000) == 3)
        #expect(WoolMeter.level(forTokens: 900_000_000) == 3)
        #expect(WoolMeter.level(forTokens: -5) == 0)
    }

    @Test func woolGrowsContinuouslyInsideATierWithoutJumps() {
        #expect(WoolMeter.amount(forTokens: 0) == 0)
        #expect(abs(WoolMeter.amount(forTokens: 125_000) - 0.5) < 1e-9)
        // Continuous across the tier boundaries
        for boundary in WoolMeter.tiers {
            let below = WoolMeter.amount(forTokens: boundary - 1)
            let at = WoolMeter.amount(forTokens: boundary)
            #expect(abs(at - below) < 0.001)
        }
        #expect(abs(WoolMeter.amount(forTokens: 250_000) - 1) < 1e-9)
        #expect(abs(WoolMeter.amount(forTokens: 2_000_000) - 2) < 1e-9)
        #expect(abs(WoolMeter.amount(forTokens: 16_000_000) - 3) < 1e-9)
        // Monotonic, capped at 4
        var last = -1.0
        for t in stride(from: 0, through: 200_000_000, by: 250_000) {
            let a = WoolMeter.amount(forTokens: t)
            #expect(a >= last)
            last = a
        }
        #expect(WoolMeter.amount(forTokens: 5_000_000_000) == WoolMeter.maxAmount)
        // The level is the whole part of the amount
        for t in [0, 100_000, 300_000, 3_000_000, 20_000_000] {
            #expect(Int(WoolMeter.amount(forTokens: t)) == WoolMeter.level(forTokens: t))
        }
    }

    @Test func theWoolMeterEasesTowardItsTargetAndShearingZeroesIt() {
        var wool = WoolState()
        wool.ease(16, tokens: 3_000_000)
        #expect(wool.shown > 0 && wool.shown < 0.1, "a swell, not a jump")
        for _ in 0..<600 { wool.ease(16, tokens: 3_000_000) }
        #expect(abs(wool.shown - WoolMeter.amount(forTokens: 3_000_000)) < 0.003)
        #expect(wool.level == 2)
        let q = wool.quantized
        #expect(q <= wool.shown && wool.shown - q < 1.0 / 16)

        wool.shear(atTokens: 3_000_000)
        #expect(wool.shown == 0)
        wool.ease(16, tokens: 3_000_000)
        #expect(wool.shown == 0, "shorn tokens don't grow back")
        wool.ease(16, tokens: 4_000_000)
        #expect(wool.shown > 0)
        wool.ease(16, tokens: 100) // the session's count restarted lower
        #expect(wool.effectiveTokens(100) == 0)
    }

    @Test func puffsGrowInCountAndSizePerLevel() {
        func layout(_ tokens: Int) -> [Puff] { LambDraw.puffLayout(amount: WoolMeter.amount(forTokens: tokens)) }
        #expect(layout(0).isEmpty)
        let l1 = layout(300_000), l2 = layout(3_000_000), l3 = layout(20_000_000), max3 = layout(100_000_000)
        #expect(l1.count < l2.count && l2.count < l3.count && l3.count <= max3.count)
        #expect(l3.count >= 12, "a ridiculous fluffball")
        #expect(max3.count == LambDraw.puffSlots.count)
        let size1 = l1.map(\.radius).max() ?? 0, size3 = max3.map(\.radius).max() ?? 0
        #expect(size3 > size1)
        // Nothing grows into the head (x 20...29, y 8...20 in the sprite)
        for puff in max3 {
            let clearOfHead = Double(puff.cx) + puff.radius + 1 <= 21 || Double(puff.cy) + puff.radius + 1 < 8
            #expect(clearOfHead, "puff \(puff.index)")
        }
    }

    @Test func pixelDiscsAreRoundish() {
        let r3 = LambDraw.discSpans(3)
        #expect(r3.map { $0.half * 2 + 1 } == [3, 5, 7, 7, 7, 5, 3])
        #expect(r3.map(\.dy) == [-3, -2, -1, 0, 1, 2, 3])
        #expect(LambDraw.discSpans(1).map { $0.half * 2 + 1 } == [1, 3, 1])
    }

    @Test func tokensFormatAsPlainKAndM() {
        #expect(AgentLamb.formatTokens(0) == "0")
        #expect(AgentLamb.formatTokens(950) == "950")
        #expect(AgentLamb.formatTokens(999) == "999")
        #expect(AgentLamb.formatTokens(1000) == "1.0K")
        #expect(AgentLamb.formatTokens(12_300) == "12.3K")
        #expect(AgentLamb.formatTokens(999_949) == "999.9K")
        #expect(AgentLamb.formatTokens(999_950) == "1.0M")
        #expect(AgentLamb.formatTokens(2_400_000) == "2.4M")
        #expect(AgentLamb.formatTokens(20_000_000) == "20.0M")
        #expect(AgentLamb.formatTokens(1_500_000_000) == "1.5B")
        #expect(AgentLamb.formatTokens(-4) == "0")
    }

    @Test func agesAndShortTexts() {
        #expect(AgentLamb.formatAge(0) == "<1m")
        #expect(AgentLamb.formatAge(59_000) == "<1m")
        #expect(AgentLamb.formatAge(14 * 60_000) == "14m")
        #expect(AgentLamb.formatAge(75 * 60_000) == "1h15m")
        #expect(AgentLamb.formatAge(-5) == "<1m")
        #expect(AgentLamb.shorten(nil, 10) == "")
        #expect(AgentLamb.shorten("  hi  ", 10) == "hi")
        #expect(AgentLamb.shorten("0123456789abc", 10) == "012345678\u{2026}")
        #expect(AgentLamb.shorten("a\nb", 10) == "a b")
    }

    @Test func theHoverCardShowsTitleStatsAndPhase() {
        withHerdWorld { world in
            var s = lambSession("a", phase: .working, tool: .edit, tokens: 2_400_000, toolName: "Edit")
            s.title = "Wire up the agent herd"
            let lamb = AgentLamb(session: s, screenWidth: herdW, screenHeight: herdH, startX: 100)
            #expect(lamb.cardLines(nowMs: world.nowMs) == [
                "Wire up the agent herd", "\u{03A3} 2.4M \u{00B7} 37 tools \u{00B7} 14m", "working: Edit",
            ])
            // No title: the repo; thinking has no tool name
            var t = lambSession("b", phase: .working, tool: .thinking, tokens: 950)
            t.toolCalls = 0
            let thinking = AgentLamb(session: t, screenWidth: herdW, screenHeight: herdH, startX: 100)
            #expect(thinking.cardLines(nowMs: world.nowMs) == [
                "co-sheep", "\u{03A3} 950 \u{00B7} 0 tools \u{00B7} 14m", "working: thinking",
            ])
            let waiting = AgentLamb(session: lambSession("c", phase: .waiting, tool: .bash, waitingFor: "Bash"),
                                    screenWidth: herdW, screenHeight: herdH, startX: 100)
            #expect(waiting.phaseLine == "waiting: Bash")
            let idle = AgentLamb(session: lambSession("d", phase: .idle), screenWidth: herdW, screenHeight: herdH,
                                 startX: 100)
            #expect(idle.phaseLine == "asleep")
            let long = AgentLamb(
                session: { var l = lambSession("e"); l.title = String(repeating: "word ", count: 20); return l }(),
                screenWidth: herdW, screenHeight: herdH, startX: 100)
            #expect(long.cardLines(nowMs: world.nowMs)[0].count <= 34)
        }
    }

    @Test func clickGateTellsAClickFromADrag() {
        let gate = ClickGate(downX: 100, downY: 100, downMs: 1000)
        #expect(!gate.becameDrag(atX: 102, 101))
        #expect(gate.becameDrag(atX: 104, 100))
        #expect(gate.becameDrag(atX: 100, 96))
        #expect(gate.isClick(upX: 101, 101, nowMs: 1200))
        #expect(!gate.isClick(upX: 101, 101, nowMs: 1350), "350 ms or more is a long press")
        #expect(!gate.isClick(upX: 110, 100, nowMs: 1100), "moved too far")
    }
}

@Suite("lamb drawing", .serialized)
struct LambDrawTests {
    private func lamb(_ s: AgentSession) -> AgentLamb {
        AgentLamb(session: s, screenWidth: herdW, screenHeight: herdH, startX: 200)
    }

    /// Put the sheep in `state`, step the lamb's own clock `steps` times 125 ms.
    private func pose(_ lamb: AgentLamb, _ state: SheepState, facingRight: Bool = true, steps: Int = 0) {
        lamb.sheep.x = 200
        lamb.sheep.y = lamb.sheep.groundY
        lamb.sheep.facingRight = facingRight
        for _ in 0..<steps {
            lamb.update(125)
            lamb.sheep.x = 200
            lamb.sheep.y = lamb.sheep.groundY
            lamb.sheep.state = state
            lamb.sheep.stateDuration = 1e12
            lamb.sheep.stateTimer = 0
        }
        lamb.sheep.state = state
        lamb.sheep.stateDuration = 1e12
        lamb.sheep.stateTimer = 0
    }

    @Test func everyToolPropDrawsInEveryPose() {
        withHerdWorld { _ in
            for tool in ToolKind.allCases {
                for facing in [true, false] {
                    for state in [SheepState.sit, .idle, .walk] {
                        let l = lamb(lambSession(phase: .working, tool: tool))
                        pose(l, state, facingRight: facing, steps: 3)
                        #expect(opCount(l) > opCount(l, overlay: false),
                                "\(tool.rawValue) \(facing ? "right" : "left") \(state.rawValue)")
                    }
                }
            }
        }
    }

    @Test func propsAreAnimatedOnTheEightFpsStep() {
        withHerdWorld { _ in
            for tool in ToolKind.allCases {
                var seen: [[DrawOp]] = []
                let l = lamb(lambSession(phase: .working, tool: tool))
                pose(l, .sit)
                for _ in 0..<30 { _ = lambOps(l) } // let the name tag fade-in finish
                for _ in 0..<12 {
                    pose(l, .sit, steps: 1)
                    let ops = lambOps(l)
                    if !seen.contains(where: { $0 == ops }) { seen.append(ops) }
                }
                #expect(seen.count >= 2, "\(tool.rawValue) never moves")
            }
        }
    }

    @Test func animationIsQuantizedSoStepsRepeatTheSameDisplayList() {
        withHerdWorld { _ in
            for tool in [ToolKind.edit, .bash, .web, .subagent, .thinking, .other, .mcp] {
                let l = lamb(lambSession(phase: .working, tool: tool))
                pose(l, .sit, steps: 2)
                for _ in 0..<30 { _ = lambOps(l) }
                let a = lambOps(l)
                l.update(40) // still inside the same 125 ms step
                pose(l, .sit)
                #expect(lambOps(l) == a, "\(tool.rawValue) re-rasterizes inside a step")
                l.update(125)
                pose(l, .sit)
                #expect(lambOps(l) != a || tool == .read, "\(tool.rawValue) should have moved on")
            }
        }
    }

    @Test func movingTheLambDoesNotChangeItsAnchoredDisplayList() {
        withHerdWorld { _ in
            let l = lamb(lambSession(phase: .working, tool: .edit, tokens: 3_000_000, subagents: 2))
            pose(l, .sit)
            for _ in 0..<200 { l.update(16); pose(l, .sit) } // wool settled, lamblets in place
            for _ in 0..<30 { _ = lambOps(l) }
            let here = lambOps(l)
            l.sheep.x = 733.37
            l.sheep.y = 412.91
            #expect(lambOps(l) == here, "pure motion must not re-rasterize")
        }
    }

    @Test func eachPhaseHasItsOwnLook() {
        withHerdWorld { _ in
            // waiting: the bobbing ?
            let waiting = lamb(lambSession(phase: .waiting, tool: .bash, waitingFor: "Bash"))
            pose(waiting, .idle, steps: 2)
            #expect(opCount(waiting) > opCount(waiting, overlay: false))
            // idle, asleep: the Zs
            let asleep = lamb(lambSession(phase: .idle))
            pose(asleep, .sleep, steps: 3)
            #expect(opCount(asleep) > opCount(asleep, overlay: false))
            // idle but standing: nothing extra
            pose(asleep, .idle)
            #expect(opCount(asleep) == opCount(asleep, overlay: false))
            // ended and trotting off: draws, wool still on
            let ended = lamb(lambSession(phase: .ended, tokens: 20_000_000))
            for _ in 0..<400 { ended.update(16) }
            pose(ended, .leaving)
            #expect(opCount(ended) > opCount(ended, overlay: false))
        }
    }

    @Test func theAskPlacardShowsWhileWaitingOnAQuestion() {
        withHerdWorld { _ in
            let ask = lamb(lambSession(phase: .waiting, tool: .ask, waitingFor: "AskUserQuestion"))
            pose(ask, .idle, steps: 2)
            let withPlacard = opCount(ask)
            let bash = lamb(lambSession(phase: .waiting, tool: .bash, waitingFor: "Bash"))
            pose(bash, .idle, steps: 2)
            #expect(withPlacard > opCount(bash), "a big placard, not just the small ?")
        }
    }

    @Test func woolPuffsAreDrawnAndGrowWithTokens() {
        withHerdWorld { _ in
            var counts: [Int] = []
            for tokens in [0, 300_000, 3_000_000, 20_000_000] {
                let l = lamb(lambSession(phase: .idle, tokens: tokens))
                for _ in 0..<400 { l.update(16) }
                pose(l, .idle)
                counts.append(opCount(l))
            }
            #expect(counts == counts.sorted())
            #expect(Set(counts).count == 4)
        }
    }

    @Test func lambletsAreDrawn() {
        withHerdWorld { _ in
            let none = lamb(lambSession(phase: .working, tool: .subagent))
            let three = lamb(lambSession(phase: .working, tool: .subagent, subagents: 3))
            for l in [none, three] {
                for _ in 0..<40 { l.update(125) }
                pose(l, .sit)
            }
            #expect(opCount(three) > opCount(none))
        }
    }

    private func stepFrame(_ herd: Herd, _ l: AgentLamb, _ canvas: Canvas, _ tiles: CanvasTileLayer) {
        l.sheep.state = .sit
        l.sheep.stateDuration = 1e12
        l.sheep.stateTimer = 0
        herd.update(16)
        canvas.beginFrame()
        herd.draw(canvas)
        tiles.sync(canvas.groups, viewport: CGRect(x: 0, y: 0, width: herdW, height: herdH), scale: 2)
    }

    @Test func aStillWorkingLambRasterizesAtEightFramesPerSecondNotSixty() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let l = landedLamb(herd, lambSession(phase: .working, tool: .edit, tokens: 3_000_000))
            let canvas = Canvas()
            let tiles = CanvasTileLayer()
            for _ in 0..<600 { stepFrame(herd, l, canvas, tiles) } // wool eased, name tag faded in
            var rasters = 0
            for _ in 0..<64 { // ~1 s of 60 fps
                l.sheep.x += 0.4 // and it drifts, which must be free
                stepFrame(herd, l, canvas, tiles)
                rasters += tiles.rasterizedLastFrame
            }
            #expect(rasters >= 4, "the prop animates")
            #expect(rasters <= 12, "rasterized \(rasters) times in a second")
        }
    }
}
