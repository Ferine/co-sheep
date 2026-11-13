import Foundation

// Ex-spectacle-render.ts: the scenes behind each spectacle (wolf scare, UFO,
// merchant, balloon, shearing day, showdown, feast, and the Christmas sleigh)
// — their update state machines and their procedural Canvas drawing.
//
// Tiles: the Flock wraps `drawSpectacleScene` in the group "spectacle". Shearing
// day paints an overlay on every participant, which can be far apart, so each
// overlay goes into its own "spectacle:shorn:<id>" group (nested inside the
// outer one) instead of stretching one tile across the screen. The sleigh and
// the present it drops are a screen apart too: "spectacle:sleigh" and
// "spectacle:gift", each anchored so flying and falling only move a node.

/// ex-`SpectacleWorld`: what a scene may ask of the flock.
struct SpectacleWorld {
    var getCharacter: (String) -> FlockCharacter?
    var characterIds: () -> [String]
    var screenW: Double
    var screenH: Double
    /// Seam for the TS `invoke("save_accessories", …)` (merchant gift): the
    /// app persists the new main-sheep accessory list and emits
    /// accessoriesChanged. nil = not wired, so the gift is skipped exactly as
    /// if the Tauri command had failed.
    var saveAccessories: (([String]) -> Bool)?

    init(getCharacter: @escaping (String) -> FlockCharacter?,
         characterIds: @escaping () -> [String],
         screenW: Double,
         screenH: Double,
         saveAccessories: (([String]) -> Bool)? = nil) {
        self.getCharacter = getCharacter
        self.characterIds = characterIds
        self.screenW = screenW
        self.screenH = screenH
        self.saveAccessories = saveAccessories
    }
}

nonisolated enum SpectaclePhase: String, CaseIterable {
    case enter, perform, exit
}

/// One running scene. A class: the TS object is mutated in place by the
/// update functions and read by the Flock afterwards. Draw code only reads it.
final class SpectacleScene {
    let type: SpectacleType
    var phase: SpectaclePhase
    var timer: Double
    var actorX: Double
    var actorY: Double
    var facingRight: Bool
    var targetId: String?
    var pairIds: (String, String)?
    var participants: [String]
    /// Per-scene scratch values (flags, one-shot markers, outcome).
    var data: [String: Double]

    init(type: SpectacleType, phase: SpectaclePhase, timer: Double, actorX: Double, actorY: Double,
         facingRight: Bool, targetId: String? = nil, pairIds: (String, String)? = nil,
         participants: [String], data: [String: Double] = [:]) {
        self.type = type
        self.phase = phase
        self.timer = timer
        self.actorX = actorX
        self.actorY = actorY
        self.facingRight = facingRight
        self.targetId = targetId
        self.pairIds = pairIds
        self.participants = participants
        self.data = data
    }

    /// JS truthiness of `scene.data[key]` (undefined and 0 are falsy).
    func flag(_ key: String) -> Bool {
        (data[key] ?? 0) != 0
    }
}

/// File-level constants of spectacle-render.ts, scoped to avoid collisions.
nonisolated enum SpectacleRenderData {
    static let SIZE: Double = 96
    static let GROUND_OFFSET: Double = SIZE + 10

    static let RELIEF = ["That was TOO close.", "Wolves. WHY wolves.", "Never speak of this."]

    static let GIFT_POOL = [
        "party_hat", "crown", "sunglasses", "bow_tie", "flower", "scarf", "top_hat",
        "monocle", "wizard_hat", "bandana", "mustache", "cape", "chef_hat", "necklace",
    ]

    static let SHEARING_BUBBLES = ["MY WOOL!", "Don't look at me.", "This is a violation.", "Cold. So cold."]
    static let SHEARING_TOTAL_MS: Double = 60_000

    // Sleigh: the nisse, his sack and a team of two flying sheep
    /// One art pixel of the sleigh, in points.
    static let SLEIGH_PX: Double = 3
    /// Sleigh plus team, nose to runner (63 art pixels).
    static let SLEIGH_LENGTH: Double = 63 * SLEIGH_PX
    static let SLEIGH_FLIGHT_MS: Double = 13_000
    static let SLEIGH_GIFT_FALL_PX_PER_MS: Double = 0.13
    /// How long a landed present waits for someone to open it.
    static let SLEIGH_GIFT_WAIT_MS: Double = 9000
    static let SLEIGH_GIFT_REACH: Double = 36
    static let SLEIGH_GIFT_W: Double = 16
    static let SLEIGH_GIFT_H: Double = 14
    static let SLEIGH_SPOTTED = [
        "Is that... a sleigh?",
        "Up there! UP THERE!",
        "Those are sheep. Pulling a sleigh. Respect.",
    ]
    static let SLEIGH_GIFT_LINES = [
        "Air mail!",
        "He does exist. Noted.",
        "A present! From the sky!",
        "I'd like to see his flight plan.",
    ]
}

func createSpectacleScene(
    _ type: SpectacleType,
    _ screenW: Double,
    _ screenH: Double,
    _ calmIds: [String],
    _ pair: (String, String)? = nil
) -> SpectacleScene {
    let SIZE = SpectacleRenderData.SIZE
    let scene = SpectacleScene(
        type: type,
        phase: type == .shearing ? .perform : .enter,
        timer: 0,
        actorX: type == .merchant ? screenW + SIZE : -SIZE,
        actorY: type == .ufo ? -SIZE
            : type == .balloon ? screenH * 0.15
            : type == .sleigh ? screenH * 0.16
            : screenH - SpectacleRenderData.GROUND_OFFSET,
        facingRight: type != .merchant,
        pairIds: pair,
        participants: calmIds
    )
    if type == .ufo {
        scene.targetId = calmIds.isEmpty ? "main" : calmIds[SimRandom.int(calmIds.count)]
    }
    if type == .sleigh {
        // The present is for the main sheep, or whoever is around to catch it
        scene.targetId = calmIds.contains("main") ? "main" : calmIds.first
    }
    return scene
}

/// Returns true while running; false once the scene is finished.
func updateSpectacleScene(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    scene.timer += dt
    switch scene.type {
    case .wolf: return updateWolf(scene, dt, world)
    case .ufo: return updateUfo(scene, dt, world)
    case .merchant: return updateMerchant(scene, dt, world)
    case .balloon: return updateBalloon(scene, dt, world)
    case .shearing: return updateShearing(scene, dt, world)
    case .showdown: return updateShowdown(scene, dt, world)
    case .feast: return updateFeast(scene, dt, world)
    case .sleigh: return updateSleigh(scene, dt, world)
    }
}

/// TS `setState(sheep, state, durationMs)`: poke the state machine directly.
private func setState(_ sheep: Sheep, _ state: SheepState, _ durationMs: Double) {
    sheep.state = state
    sheep.stateTimer = 0
    sheep.stateDuration = durationMs
}

private func updateWolf(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SIZE = SpectacleRenderData.SIZE
    let speed = 0.35 // px per ms
    if scene.phase == .enter {
        scene.actorX += speed * dt
        if scene.actorX >= world.screenW * 0.3 || scene.timer > 2000 {
            scene.phase = .perform
            scene.timer = 0
            // Flock flees.
            for id in world.characterIds() {
                guard let c = world.getCharacter(id) else { continue }
                let away = c.sheep.x < scene.actorX ? 0 : world.screenW - SIZE
                c.sheep.walkTarget = away
                c.sheep.playAnimation(.zoom)
            }
        }
    } else if scene.phase == .perform {
        if scene.timer > 3000 && !scene.flag("gcQuip") {
            scene.data["gcQuip"] = 1
            if let gc = world.getCharacter("good_colleague"), !gc.bubble.visible {
                gc.bubble.show("Jeg var IKKE redd.", duration: 4000)
            }
        }
        if scene.timer > 6000 {
            scene.phase = .exit
            scene.timer = 0
            scene.facingRight = false
        }
    } else {
        scene.actorX -= speed * 1.4 * dt
        if scene.actorX < -SIZE {
            // Survivors catch their breath once the wolf is gone.
            let RELIEF = SpectacleRenderData.RELIEF
            var shown = 0
            for id in scene.participants {
                if shown >= 2 { break }
                guard let c = world.getCharacter(id), !c.bubble.visible else { continue }
                c.bubble.show(RELIEF[SimRandom.int(RELIEF.count)], duration: 3500)
                shown += 1
            }
            return false
        }
    }
    return true
}

private func updateUfo(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SIZE = SpectacleRenderData.SIZE
    guard let target = world.getCharacter(scene.targetId ?? "main") else { return false }
    let hoverY = world.screenH * 0.25
    if scene.phase == .enter {
        scene.actorX = target.sheep.x + SIZE / 2 - 40
        scene.actorY = min(hoverY, scene.actorY + 0.3 * dt)
        if scene.actorY >= hoverY || scene.timer > 2500 {
            scene.phase = .perform
            scene.timer = 0
            setState(target.sheep, .grabbed, 8000)
        }
    } else if scene.phase == .perform {
        // Beam the target upward.
        let liftTo = scene.actorY + 90
        if target.sheep.y > liftTo { target.sheep.y -= 0.15 * dt }
        if scene.timer > 8000 {
            scene.phase = .exit
            scene.timer = 0
            setState(target.sheep, .fall, 4000)
        }
    } else {
        scene.actorY -= 0.4 * dt
        if scene.actorY < -120 || scene.timer > 2000 {
            if !target.bubble.visible { target.bubble.show("I have SEEN things.", duration: 5000) }
            target.sheep.playAnimation(.spin)
            return false
        }
    }
    return true
}

private func updateMerchant(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SIZE = SpectacleRenderData.SIZE
    let speed = 0.2
    if scene.phase == .enter {
        scene.actorX -= speed * dt
        if scene.actorX <= world.screenW * 0.6 || scene.timer > 4000 {
            scene.phase = .perform
            scene.timer = 0
            if let main = world.getCharacter("main") {
                main.sheep.walkTarget = scene.actorX - SIZE
                if !main.bubble.visible { main.bubble.show("A traveling merchant!", duration: 3500) }
            }
        }
    } else if scene.phase == .perform {
        if scene.timer > 6000 {
            scene.phase = .exit
            scene.timer = 0
            scene.facingRight = true
            giftAccessory(world)
        }
    } else {
        scene.actorX += speed * 1.5 * dt
        if scene.actorX > world.screenW + SIZE { return false }
    }
    return true
}

/// Gift the main sheep one accessory it doesn't own yet (TS: fire-and-forget
/// promise chain of `get_accessories` → `save_accessories`; the config read is
/// direct here, the save goes through `SpectacleWorld.saveAccessories`).
private func giftAccessory(_ world: SpectacleWorld) {
    let owned = Config.loadConfig()?.accessories ?? []
    let options = SpectacleRenderData.GIFT_POOL.filter { !owned.contains($0) }
    if options.isEmpty { return }
    let gift = options[SimRandom.int(options.count)]
    guard let save = world.saveAccessories else {
        Log.info("flock", "merchant gift failed: save_accessories is not wired")
        return
    }
    guard save(owned + [gift]) else { return } // failed save: no "gift" bubble
    if let main = world.getCharacter("main") {
        if !main.bubble.visible { main.bubble.show("Ooh, a gift!", duration: 4000) }
        main.sheep.playAnimation(.bounce)
    }
}

private func updateBalloon(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    if scene.phase == .enter {
        scene.phase = .perform
        scene.timer = 0
        scene.actorX = -60
        for id in scene.participants {
            if let c = world.getCharacter(id) { setState(c.sheep, .sit, 20000) }
        }
    } else {
        scene.actorX += ((world.screenW + 120) / 20000) * dt
        if scene.timer > 5000 && !scene.flag("ooh") {
            scene.data["ooh"] = 1
            let c = scene.participants.first.flatMap { world.getCharacter($0) }
            if let c, !c.bubble.visible { c.bubble.show("Ooooh.", duration: 3000) }
        }
        for id in scene.participants {
            if let c = world.getCharacter(id) {
                c.sheep.facingRight = scene.actorX > c.sheep.x // track the balloon
            }
        }
        if scene.actorX > world.screenW + 60 { return false }
    }
    return true
}

private func updateShearing(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SHEARING_BUBBLES = SpectacleRenderData.SHEARING_BUBBLES
    // Scene is created directly in "perform"; the shorn overlay is drawn
    // by drawShornOverlays and fades back in over the final 10 s.
    if !scene.flag("started") {
        scene.data["started"] = 1
        for id in scene.participants {
            world.getCharacter(id)?.sheep.playAnimation(.vibrate)
        }
    }
    for i in 0..<SHEARING_BUBBLES.count {
        let flag = "bubble\(i)"
        if scene.timer > Double(i) * 2000 && !scene.flag(flag) {
            scene.data[flag] = 1
            let id: String? = scene.participants.isEmpty
                ? nil : scene.participants[i % max(1, scene.participants.count)]
            let c = id.flatMap { world.getCharacter($0) }
            if let c, !c.bubble.visible { c.bubble.show(SHEARING_BUBBLES[i], duration: 3000) }
        }
    }
    return scene.timer < SpectacleRenderData.SHEARING_TOTAL_MS
}

private let TUMBLEWEED_START_X: Double = -20
private let TUMBLEWEED_PX_PER_MS: Double = 0.24

private func updateShowdown(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SIZE = SpectacleRenderData.SIZE
    guard let pairIds = scene.pairIds else { return false }
    guard let a = world.getCharacter(pairIds.0), let b = world.getCharacter(pairIds.1) else { return false }
    let center = world.screenW / 2
    let aSpot = center - 60 - SIZE / 2
    let bSpot = center + 60 - SIZE / 2

    if scene.phase == .enter {
        if !scene.flag("summoned") {
            scene.data["summoned"] = 1
            a.sheep.walkTarget = aSpot
            b.sheep.walkTarget = bSpot
            for id in scene.participants {
                if id == pairIds.0 || id == pairIds.1 { continue }
                if let c = world.getCharacter(id) { setState(c.sheep, .sit, 15000) } // spectators settle in
            }
        }
        let gathered = abs(a.sheep.x - aSpot) < SIZE && abs(b.sheep.x - bSpot) < SIZE
        if gathered || scene.timer > 5000 {
            scene.phase = .perform
            scene.timer = 0
        }
    } else if scene.phase == .perform {
        // The tumbleweed rolls in sim time (the TS moved it 4px per draw call,
        // i.e. at the redraw rate; 0.24 px/ms is that at 60 fps).
        scene.data["tumbleX"] = (scene.data["tumbleX"] ?? TUMBLEWEED_START_X) + TUMBLEWEED_PX_PER_MS * dt
        a.sheep.facingRight = b.sheep.x > a.sheep.x
        b.sheep.facingRight = a.sheep.x > b.sheep.x
        if !scene.flag("vibe0") {
            scene.data["vibe0"] = 1
            a.sheep.playAnimation(.vibrate)
            b.sheep.playAnimation(.vibrate)
        }
        if scene.timer > 4000 && !scene.flag("vibe4") {
            scene.data["vibe4"] = 1
            a.sheep.playAnimation(.vibrate)
            b.sheep.playAnimation(.vibrate)
        }
        if scene.timer > 8000 {
            scene.phase = .exit
            scene.timer = 0
            scene.data["reconciled"] = SimRandom.next() < 0.5 ? 1 : 0
            let rec = scene.data["reconciled"] == 1
            if !a.bubble.visible { a.bubble.show(rec ? "...truce?" : "This isn't over.", duration: 4000) }
            if !b.bubble.visible { b.bubble.show(rec ? "...fine. Truce." : "Not even CLOSE to over.", duration: 4000) }
        }
    } else if scene.timer > 2000 {
        return false
    }
    return true
}

private func updateFeast(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let SIZE = SpectacleRenderData.SIZE
    let center = world.screenW / 2
    if scene.phase == .enter {
        if !scene.flag("gathered") {
            scene.data["gathered"] = 1
            var slot = 0
            for id in scene.participants {
                guard let c = world.getCharacter(id) else { continue }
                c.sheep.walkTarget = center + (Double(slot) - Double(scene.participants.count) / 2) * SIZE * 0.9
                slot += 1
            }
        }
        if scene.timer > 6000 {
            scene.phase = .perform
            scene.timer = 0
            let host = scene.pairIds?.0 ?? scene.participants.first
            let hostChar = host.flatMap { world.getCharacter($0) }
            if let hostChar {
                setState(hostChar.sheep, .idleCampfire, 15000)
                hostChar.sheep.campfireSparks = []
            }
            for id in scene.participants {
                if id == host { continue }
                if let c = world.getCharacter(id) { setState(c.sheep, .sit, 15000) }
            }
        }
    } else if scene.phase == .perform {
        if scene.timer > 2000 && !scene.flag("toasted"), let pairIds = scene.pairIds {
            scene.data["toasted"] = 1
            let a = world.getCharacter(pairIds.0)
            let b = world.getCharacter(pairIds.1)
            if let a, !a.bubble.visible { a.bubble.show("To making up!", duration: 3500) }
            if let b {
                SimTimers.after(1200) {
                    if !b.bubble.visible { b.bubble.show("To wool and friendship!", duration: 3500) }
                }
            }
        }
        if scene.timer > 15000 {
            scene.phase = .exit
            scene.timer = 0
            for id in scene.participants {
                if let c = world.getCharacter(id) {
                    let dir: Double = SimRandom.next() > 0.5 ? 1 : -1
                    c.sheep.walkTarget = c.sheep.x + dir * (SIZE * 2 + SimRandom.next() * SIZE * 3)
                }
            }
        }
    } else if scene.timer > 3000 {
        return false
    }
    return true
}

/// The sleigh crosses the sky left to right, drops one present by parachute
/// and is gone; whoever the present was for walks over and opens it. Scene
/// time lives in `data["clock"]` (the phase timer restarts when it lands).
private func updateSleigh(_ scene: SpectacleScene, _ dt: Double, _ world: SpectacleWorld) -> Bool {
    let D = SpectacleRenderData.self
    let clock = (scene.data["clock"] ?? 0) + dt
    scene.data["clock"] = clock
    let recipient = scene.targetId.flatMap { world.getCharacter($0) }

    if scene.phase == .enter {
        scene.phase = .perform
        scene.timer = 0
        scene.actorX = -D.SLEIGH_LENGTH
        for id in scene.participants {
            if let c = world.getCharacter(id) { setState(c.sheep, .sit, 16000) }
        }
        // Drop it beside the recipient, not on its head
        let aim = recipient.map { $0.sheep.x + $0.sheep.displaySize / 2 + 70 } ?? world.screenW / 2
        scene.data["dropX"] = min(max(aim, world.screenW * 0.15), world.screenW * 0.85)
        return true
    }

    if scene.phase == .perform {
        scene.actorX += ((world.screenW + D.SLEIGH_LENGTH * 2) / D.SLEIGH_FLIGHT_MS) * dt
        if scene.timer > 2500 && !scene.flag("spotted") {
            scene.data["spotted"] = 1
            let c = scene.participants.first.flatMap { world.getCharacter($0) }
            if let c, !c.bubble.visible {
                c.bubble.show(D.SLEIGH_SPOTTED[SimRandom.int(D.SLEIGH_SPOTTED.count)], duration: 3500)
            }
        }
        // Heads follow the sleigh until the present is the more interesting thing
        if !scene.flag("landed") {
            let sleighX = scene.actorX + D.SLEIGH_LENGTH / 2
            for id in scene.participants {
                if let c = world.getCharacter(id) { c.sheep.facingRight = sleighX > c.sheep.x }
            }
        }
        if scene.actorX > world.screenW + 40 { scene.phase = .exit }
    }

    // The present leaves the sleigh above its landing spot...
    let dropX = scene.data["dropX"] ?? world.screenW / 2
    if !scene.flag("dropped") && scene.actorX + 30 >= dropX {
        scene.data["dropped"] = 1
        scene.data["giftX"] = dropX
        scene.data["giftY"] = scene.actorY + 30
    }
    guard scene.flag("dropped"), let giftX = scene.data["giftX"], let giftY = scene.data["giftY"] else {
        // Nothing dropped: the scene is over once the sleigh is gone
        return scene.phase != .exit
    }

    // ...floats down on its parachute...
    let landY = world.screenH - Sheep.DOCK_MARGIN - 3
    if !scene.flag("landed") {
        let y = giftY + D.SLEIGH_GIFT_FALL_PX_PER_MS * dt
        scene.data["giftY"] = min(y, landY)
        if y >= landY {
            scene.data["landed"] = 1
            scene.data["landedAt"] = clock
        }
        return true
    }

    // ...and waits for its sheep, which walks over by facing (walkTarget
    // would stop it a sheep and a half short).
    if scene.data["openedAt"] == nil {
        var opened = clock - (scene.data["landedAt"] ?? clock) > D.SLEIGH_GIFT_WAIT_MS
        if let recipient, recipient.sheep.canBeDirected {
            let sheep = recipient.sheep
            let center = sheep.x + sheep.displaySize / 2
            if abs(center - giftX) < D.SLEIGH_GIFT_REACH {
                opened = true
                scene.data["caught"] = 1
                sheep.playAnimation(.bounce)
                recipient.bubble.show(D.SLEIGH_GIFT_LINES[SimRandom.int(D.SLEIGH_GIFT_LINES.count)], duration: 4000)
            } else {
                sheep.walkTarget = nil
                sheep.facingRight = giftX > center
                if sheep.state != .walk { setState(sheep, .walk, 15000) }
            }
        }
        if opened { scene.data["openedAt"] = clock }
        return true
    }

    // Sparkles, then done (once the sleigh has left the screen too)
    let sparkled = clock - (scene.data["openedAt"] ?? clock) > 1400
    return !(sparkled && scene.phase == .exit)
}

func drawSpectacleScene(_ scene: SpectacleScene, _ ctx: Canvas, _ world: SpectacleWorld) {
    switch scene.type {
    case .wolf: drawWolf(ctx, scene.actorX, scene.actorY, scene.facingRight)
    case .ufo: drawUfo(ctx, scene.actorX, scene.actorY, scene.phase == .perform)
    case .merchant: drawMerchant(ctx, scene.actorX, scene.actorY, scene.facingRight)
    case .balloon: drawBalloon(ctx, scene.actorX, scene.actorY)
    case .shearing: drawShornOverlays(ctx, scene, world)
    case .showdown: drawTumbleweed(ctx, scene, world)
    case .feast: break // campfire visuals come from the existing idle_campfire state
    case .sleigh: drawSleighScene(ctx, scene, world)
    }
}

// Sleigh art, one character per art pixel, drawn left to right: the sleigh
// (nisse and sack aboard), then the team.
private let SLEIGH_ART = [
    "....hh..............",
    "...hhhh.............",
    "..wwwwww............",
    "...ffff.....ss......",
    "...bbbb....ssss.....",
    "..ccbbcc..ssssss....",
    "RRccccccRRssssssRR..",
    "RRRRRRRRRRRRRRRRRRR.",
    ".RRRRRRRRRRRRRRRRRRg",
    "..g......g......g.g.",
    "gggggggggggggggggg..",
]

private let SLEIGH_PALETTE: [Character: String] = [
    "h": "#E0362F", "w": "#FFFFFF", "f": "#F2C9A0", "b": "#FFFFFF", "c": "#E0362F",
    "s": "#8B5A2B", "R": "#9C1F2E", "g": "#FFD54A",
]

/// A flying sheep in antlers. `n` is the nose: red on the lead animal.
private let SLEIGH_SHEEP_BODY = [
    ".........a.a.",
    "..WWWWW..aaa.",
    ".WWWWWWWHHHH.",
    "WWWWWWWWHHHHn",
    "WWWWWWWWHHHH.",
    ".WWWWWWWW....",
    "..WWWWWW.....",
]

/// Two gallop frames: legs flung out, legs gathered.
private let SLEIGH_SHEEP_LEGS = [
    ["..L.L..L.L...", ".L...L.L...L."],
    ["...LL..LL....", "...L....L...."],
]

private func sleighSheepPalette(lead: Bool) -> [Character: String] {
    ["W": "#F5F5F0", "H": "#3A3A44", "a": "#8B5A2B", "L": "#3A3A44", "n": lead ? "#FF3B30" : "#3A3A44"]
}

private func drawSleighScene(_ ctx: Canvas, _ scene: SpectacleScene, _ world: SpectacleWorld) {
    let D = SpectacleRenderData.self
    let clock = scene.data["clock"] ?? 0

    if scene.phase == .perform {
        let bob = sin(clock / 700) * 5
        let x = scene.actorX
        let y = scene.actorY + bob
        ctx.group("spectacle:sleigh", anchor: CGPoint(x: x, y: y)) {
            drawSleighTeam(ctx, x, y, clock)
        }
    }

    guard scene.flag("dropped"), let giftX = scene.data["giftX"], let giftY = scene.data["giftY"] else { return }
    if let openedAt = scene.data["openedAt"] {
        // Popped: a second and a half of sparkles where it stood
        let left = 1.4 - (clock - openedAt) / 1000
        if left > 0 {
            let cy = giftY - D.SLEIGH_GIFT_H / 2
            ctx.group("spectacle:gift", anchor: CGPoint(x: giftX, y: cy)) {
                ChristmasTheme.drawSparkle(ctx, giftX, cy, left + 0.6, clock / 1000)
            }
        }
        return
    }

    let falling = !scene.flag("landed")
    let x = giftX + (falling ? sin(clock / 400) * 6 : 0)
    ctx.save()
    defer { ctx.restore() }
    ctx.group("spectacle:gift", anchor: CGPoint(x: x, y: giftY)) {
        if falling {
            // Parachute: a white canopy and two lines down to the box
            let top = giftY - D.SLEIGH_GIFT_H
            ctx.strokeStyle = "rgba(255, 255, 255, 0.8)"
            ctx.lineWidth = 1
            ctx.lineJoin = "round"
            ctx.beginPath()
            ctx.moveTo(x - 13, top - 16)
            ctx.lineTo(x - D.SLEIGH_GIFT_W / 2, top)
            ctx.moveTo(x + 13, top - 16)
            ctx.lineTo(x + D.SLEIGH_GIFT_W / 2, top)
            ctx.stroke()
            ctx.fillStyle = "#F4F8FF"
            ctx.beginPath()
            ctx.ellipse(x, top - 16, 14, 10, 0, Double.pi, Double.pi * 2)
            ctx.fill()
            ctx.fillStyle = "#D62B2B"
            ctx.beginPath()
            ctx.ellipse(x, top - 16, 5, 10, 0, Double.pi, Double.pi * 2)
            ctx.fill()
        }
        ChristmasTheme.drawPresent(ctx, x, giftY, D.SLEIGH_GIFT_W, D.SLEIGH_GIFT_H, "#D62B2B", "#FFD54A")
    }
}

/// The sleigh with its top-left corner at (x, y), facing right.
private func drawSleighTeam(_ ctx: Canvas, _ x: Double, _ y: Double, _ clock: Double) {
    let px = SpectacleRenderData.SLEIGH_PX
    let pen = PixelPen(ctx: ctx, ox: x, oy: y, px: px, flip: false)
    let gallop = Int(clock / 180) % 2

    ctx.save()
    // Star dust trailing behind, stepping ten times a second
    let twinkle = Int(clock / 100)
    ctx.fillStyle = "#FFD54A"
    for i in 0..<5 {
        ctx.globalAlpha = 0.75 - Double(i) * 0.14
        let size: Double = (twinkle + i) % 2 == 0 ? 3 : 2
        ctx.fillRect(x - 10 - Double(i) * 13, y + 18 + sin(Double(twinkle + i * 2) * 0.9) * 5, size, size)
    }
    ctx.globalAlpha = 1

    // Reins from the sleigh's prow to each collar
    ctx.strokeStyle = "#6B4423"
    ctx.lineWidth = 1.5
    ctx.lineJoin = "round"
    ctx.beginPath()
    ctx.moveTo(x + 19 * px, y + 7 * px)
    ctx.lineTo(x + 31 * px, y + 6 * px)
    ctx.lineTo(x + 47 * px, y + 6 * px)
    ctx.stroke()

    pen.sprite(SLEIGH_ART, 0, 0, SLEIGH_PALETTE)
    // The second sheep gallops half a stride out of step
    for (index, gx) in [22.0, 38.0].enumerated() {
        let lead = index == 1
        let rise: Double = (gallop + index) % 2 == 0 ? 0 : 1
        pen.sprite(SLEIGH_SHEEP_BODY, gx, 1 + rise, sleighSheepPalette(lead: lead))
        pen.sprite(SLEIGH_SHEEP_LEGS[(gallop + index) % 2], gx, 8 + rise, sleighSheepPalette(lead: lead))
    }
    ctx.restore()
}

private func drawWolf(_ ctx: Canvas, _ x: Double, _ y: Double, _ facingRight: Bool) {
    ctx.save()
    ctx.translate(x + 48, y + 48)
    if !facingRight { ctx.scale(-1, 1) }
    ctx.translate(-48, -48)
    let s = 3.0
    ctx.fillStyle = "#4a4a55" // body
    ctx.fillRect(8 * s, 14 * s, 18 * s, 8 * s)
    ctx.fillRect(22 * s, 9 * s, 8 * s, 7 * s) // head
    ctx.fillStyle = "#3a3a44"
    ctx.fillRect(27 * s, 6 * s, 3 * s, 4 * s) // ear
    ctx.fillRect(4 * s, 13 * s, 5 * s, 3 * s) // tail
    ctx.fillRect(9 * s, 22 * s, 3 * s, 5 * s) // legs
    ctx.fillRect(14 * s, 22 * s, 3 * s, 5 * s)
    ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s)
    ctx.fillRect(23 * s, 22 * s, 3 * s, 5 * s)
    ctx.fillStyle = "#e94560" // eye
    ctx.fillRect(26 * s, 10 * s, 2 * s, 2 * s)
    ctx.fillStyle = "#ffffff" // fang
    ctx.fillRect(29 * s, 14 * s, 1 * s, 2 * s)
    ctx.restore()
}

private func drawUfo(_ ctx: Canvas, _ x: Double, _ y: Double, _ beamOn: Bool) {
    ctx.save()
    if beamOn {
        let grad = ctx.createLinearGradient(x + 40, y + 20, x + 40, y + 400)
        grad.addColorStop(0, "rgba(120, 255, 160, 0.35)")
        grad.addColorStop(1, "rgba(120, 255, 160, 0)")
        ctx.fillStyle = grad
        ctx.beginPath()
        ctx.moveTo(x + 25, y + 20)
        ctx.lineTo(x + 55, y + 20)
        ctx.lineTo(x + 95, y + 400)
        ctx.lineTo(x - 15, y + 400)
        ctx.closePath()
        ctx.fill()
    }
    ctx.fillStyle = "#8899aa" // saucer
    ctx.beginPath()
    ctx.ellipse(x + 40, y + 14, 40, 12, 0, 0, Double.pi * 2)
    ctx.fill()
    ctx.fillStyle = "#bfe8ff" // dome
    ctx.beginPath()
    ctx.arc(x + 40, y + 6, 14, Double.pi, 0)
    ctx.fill()
    ctx.fillStyle = "#ffe066" // lights
    let t = Int((SimClock.nowMs() / 300).rounded(.down)) % 3
    for i in 0..<3 {
        ctx.globalAlpha = i == t ? 1 : 0.35
        ctx.fillRect(x + 18 + Double(i) * 20, y + 16, 6, 4)
    }
    ctx.restore()
}

private func drawMerchant(_ ctx: Canvas, _ x: Double, _ y: Double, _ facingRight: Bool) {
    let s = 3.0
    ctx.save()
    ctx.translate(x + 48, y + 48)
    if !facingRight { ctx.scale(-1, 1) }
    ctx.translate(-48, -48)
    ctx.fillStyle = "#9a9aa5" // grey wool body
    ctx.fillRect(8 * s, 12 * s, 16 * s, 10 * s)
    ctx.fillRect(21 * s, 8 * s, 7 * s, 8 * s) // head
    ctx.fillStyle = "#6f6f7a"
    ctx.fillRect(10 * s, 22 * s, 3 * s, 5 * s) // legs
    ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s)
    ctx.fillStyle = "#1a1a2e" // top hat
    ctx.fillRect(21 * s, 3 * s, 7 * s, 2 * s)
    ctx.fillRect(22.5 * s, 0 * s, 4 * s, 3 * s)
    ctx.fillStyle = "#7a5230" // wares bundle
    ctx.fillRect(6 * s, 8 * s, 7 * s, 6 * s)
    ctx.strokeStyle = "#4d3319"
    ctx.lineWidth = 2
    ctx.strokeRect(6 * s, 8 * s, 7 * s, 6 * s)
    ctx.fillStyle = "#1a1a2e" // eye
    ctx.fillRect(25 * s, 10 * s, 2 * s, 2 * s)
    ctx.restore()
}

private func drawBalloon(_ ctx: Canvas, _ x: Double, _ y: Double) {
    ctx.save()
    let bob = sin(SimClock.nowMs() / 900) * 6
    let by = y + bob
    ctx.fillStyle = "#e94560" // envelope
    ctx.beginPath()
    ctx.arc(x, by, 34, Double.pi * 0.95, Double.pi * 2.05)
    ctx.fill()
    ctx.fillStyle = "#d4a520"
    ctx.beginPath()
    ctx.arc(x, by, 34, Double.pi * 1.25, Double.pi * 1.75)
    ctx.fill()
    ctx.strokeStyle = "#6f4e37" // ropes
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(x - 20, by + 24); ctx.lineTo(x - 9, by + 48)
    ctx.moveTo(x + 20, by + 24); ctx.lineTo(x + 9, by + 48)
    ctx.stroke()
    ctx.fillStyle = "#7a5230" // basket
    ctx.fillRect(x - 11, by + 48, 22, 14)
    ctx.restore()
}

private func drawShornOverlays(_ ctx: Canvas, _ scene: SpectacleScene, _ world: SpectacleWorld) {
    // Pink "naked" ellipse over each sheep's wool; fades back in the last 10s.
    let total: Double = 60_000
    let fadeStart = total - 10_000
    let alpha = scene.timer < fadeStart ? 0.65 : 0.65 * (1 - (scene.timer - fadeStart) / 10_000)
    if alpha <= 0 { return }
    ctx.save()
    ctx.globalAlpha = max(0, alpha)
    ctx.fillStyle = "#f2b9c4"
    for id in scene.participants {
        guard let c = world.getCharacter(id) else { continue }
        let sz = c.sheep.displaySize
        // One tile per sheep: the participants can be a screen apart.
        ctx.group("spectacle:shorn:\(id)") {
            ctx.beginPath()
            ctx.ellipse(c.sheep.x + sz * 0.45, c.sheep.y + sz * 0.55, sz * 0.32, sz * 0.24, 0, 0, Double.pi * 2)
            ctx.fill()
        }
    }
    ctx.restore()
}

private func drawTumbleweed(_ ctx: Canvas, _ scene: SpectacleScene, _ world: SpectacleWorld) {
    if scene.phase != .perform { return }
    let x = scene.data["tumbleX"] ?? TUMBLEWEED_START_X
    let y = world.screenH - 130 + abs(sin(x / 40)) * -18
    ctx.save()
    ctx.strokeStyle = "#b0925a"
    ctx.lineWidth = 2
    ctx.translate(x, y)
    ctx.rotate(x / 30)
    ctx.beginPath()
    ctx.arc(0, 0, 12, 0, Double.pi * 2)
    for i in 0..<4 {
        ctx.moveTo(-12, 0)
        ctx.quadraticCurveTo(0, (Double(i) - 1.5) * 8, 12, 0)
    }
    ctx.stroke()
    ctx.restore()
}
