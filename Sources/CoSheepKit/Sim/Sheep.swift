import Foundation

// Ex-sheep.ts: one sheep (the main one, the Good Colleague, or a friend).
// The state machine and the draw code are line-for-line ports; `ctx` is a
// `Canvas`. The caller (Flock) wraps `draw` in `ctx.group(...)`.

typealias DrawOverlay = (Canvas, Double, Double, Double, Bool, SheepState) -> Void

/// A campfire spark (ex-`{ x, y, life }` literal).
struct CampfireSpark: Equatable {
    var x: Double
    var y: Double
    var life: Double
}

final class Sheep {
    // MARK: Constants (file-level in sheep.ts; scoped here so they can't
    // collide with the same-named constants other files declare)

    static let SPRITE_SIZE: Double = 32
    static let SCALE: Double = 3
    static let DISPLAY_SIZE: Double = SPRITE_SIZE * SCALE
    static let WALK_SPEED: Double = 60 // px/sec
    static let DOCK_MARGIN: Double = 80 // stay above macOS Dock
    static let ZOOM_SPEED: Double = 600 // px/sec
    static let BORED_THRESHOLD: Double = 120000 // 2 minutes until bored idle behaviors

    /// States safe to interrupt when the sheep should sit and listen to the
    /// human. Physics states (grabbed, parachute, fall, trampoline, stampede,
    /// stacked) and reply animations play out first, then park on landing.
    static let LISTENING_PARKABLE: [SheepState] = [
        .idle, .walk, .sit, .sleep,
        .idleSleep, .idleCampfire, .idleCounting, .idleJudging,
        .idleHearts, .idleZooming, .idleSighing, .idleEggPainting,
    ]

    // MARK: Properties

    let id: String
    let tint: String?
    let scaleMultiplier: Double
    var name: String
    var personality: FriendPersonality?
    var x: Double
    var y: Double
    var vx: Double = 0
    var vy: Double = 0
    var state: SheepState = .parachute
    var facingRight: Bool = true
    var walkTarget: Double?
    var drawOverlay: DrawOverlay?
    var seasonalOverlay: DrawOverlay?

    // Stacking. Weak: Flock owns every sheep, and a strong pair would be a
    // retain cycle.
    weak var stackedOn: Sheep?
    weak var stackedBy: Sheep?

    // Trampoline
    var trampolineBounces: Int = 0
    private var trampolineFlipProgress: Double = 0

    // Window platforms
    var platforms: [WindowPlatform] = []
    var currentPlatform: WindowPlatform?

    var screenWidth: Double
    var screenHeight: Double
    // stateTimer / stateDuration / campfireSparks are `private` in the TS but
    // GroupActivities, SpectacleRender and Flock poke them via `as any`.
    var stateTimer: Double = 0
    var stateDuration: Double = 0
    private var lastActivityTime: Double = SimClock.nowMs()
    var campfireSparks: [CampfireSpark] = []
    private var nameTagAlpha: Double = 0
    /// ex-`setEasterTheme(theme)`; `EasterTheme` conforms to `EasterThemeHooks`.
    var easterTheme: EasterThemeHooks?
    private var eggPaintingRegistered = false
    private var listening = false
    private var idleZoomBurst = false

    private var sprites: [String: SpriteSheet]

    init(
        _ screenWidth: Double,
        _ screenHeight: Double,
        _ id: String = "main",
        _ tint: String? = nil,
        _ startX: Double? = nil,
        _ scaleMultiplier: Double? = nil
    ) {
        self.id = id
        self.tint = tint
        self.scaleMultiplier = scaleMultiplier ?? 1.0
        self.name = "Sheep"
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        // Start from top for parachute entrance
        let ds = (Self.DISPLAY_SIZE * self.scaleMultiplier).rounded()
        self.x = startX ?? screenWidth / 2 - ds / 2
        self.y = -ds

        self.sprites = [
            "idle": SpriteSheet("/assets/sprites/sheep-idle.png", 32, 32, 2, 2),
            "walk": SpriteSheet("/assets/sprites/sheep-walk.png", 32, 32, 4, 6),
            "parachute": SpriteSheet("/assets/sprites/sheep-parachute.png", 32, 32, 2, 3),
            "sit": SpriteSheet("/assets/sprites/sheep-sit.png", 32, 32, 1, 1),
            "sleep": SpriteSheet("/assets/sprites/sheep-sleep.png", 32, 32, 2, 2),
            "fall": SpriteSheet("/assets/sprites/sheep-fall.png", 32, 32, 1, 1),
        ]
    }

    func setEasterTheme(_ easterTheme: EasterThemeHooks?) {
        self.easterTheme = easterTheme
    }

    var groundY: Double {
        screenHeight - displaySize - Self.DOCK_MARGIN
    }

    /// Ground level accounting for the window platform we're standing on
    private var effectiveGroundY: Double {
        if let platform = currentPlatform {
            let landY = platform.y - displaySize
            if landY < groundY { return landY }
        }
        return groundY
    }

    var displaySize: Double {
        (Self.DISPLAY_SIZE * scaleMultiplier).rounded()
    }

    private var drawScale: Double {
        Self.SCALE * scaleMultiplier
    }

    private var walkSpeed: Double {
        Self.WALK_SPEED * scaleMultiplier
    }

    /// Reset boredom timer — call on any user interaction or AI commentary.
    func resetActivity() {
        lastActivityTime = SimClock.nowMs()
        // Break out of bored states
        if state == .idleSleep ||
            state == .idleCampfire ||
            state == .idleCounting ||
            state == .idleJudging ||
            state == .idleHearts ||
            state == .idleZooming ||
            state == .idleSighing ||
            state == .idleEggPainting {
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func isBored() -> Bool {
        SimClock.nowMs() - lastActivityTime > Self.BORED_THRESHOLD
    }

    /// True while the human has this sheep's chat open — pickers must not disturb it.
    var isListening: Bool {
        listening
    }

    /// Park the sheep while the human is chatting — it stops and listens.
    func startListening() {
        listening = true
        resetActivity()
    }

    func stopListening() {
        listening = false
        if state == .sit {
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    /// Trigger a named animation. Interrupts idle/walk/sit but not grabbed.
    func playAnimation(_ anim: SheepAnimation) {
        if state == .grabbed || state == .parachute { return }
        // Leaving a stack via an animation must clear the stack pointers, or
        // the bottom sheep stays "occupied" and later flings us from afar
        if state == .stacked { unstack() }
        resetActivity()
        Log.info("sheep", "[\(id)] Playing animation: \(anim.rawValue)")

        switch anim {
        case .bounce:
            setState(.bounce, 1200)
            vy = -300
        case .spin:
            setState(.spin, 800)
        case .backflip:
            setState(.backflip, 600)
            vy = -200
        case .headshake:
            setState(.headshake, 800)
        case .zoom:
            setState(.zoom, 1500)
            facingRight = SimRandom.next() > 0.5
        case .vibrate:
            setState(.vibrate, 1000)
        }
    }

    /// Called when the user clicks on the sheep to start dragging.
    func grab() {
        resetActivity()
        // If something is stacked on us, make it fall
        if let by = stackedBy {
            by.stackedOn = nil
            by.vy = -150
            by.setState(.fall, 0)
            stackedBy = nil
        }
        // If we're stacked on something, unstack
        if let on = stackedOn {
            on.stackedBy = nil
            stackedOn = nil
        }
        currentPlatform = nil
        state = .grabbed
        stateTimer = 0
        vx = 0
        vy = 0
    }

    /// Called when the user releases the sheep. Parachutes if airborne, trampolines if very high.
    func release() {
        let trampolineThreshold = screenHeight * 0.35
        if y < trampolineThreshold {
            // Very high up — trampoline mode!
            startTrampoline()
        } else if y < groundY - 10 {
            // Airborne — deploy parachute
            state = .parachute
            stateTimer = 0
            vy = 0
            vx = 0
            if let sprite = sprites["parachute"] { sprite.reset() }
        } else {
            // On or near ground
            y = groundY
            state = .idle
            stateTimer = 0
            stateDuration = 1000 + SimRandom.next() * 2000
        }
    }

    /// Start petting — called when cursor hovers over sheep for a while.
    func startPetting() {
        if state == .grabbed || state == .parachute { return }
        if state == .petting { return }
        resetActivity()
        Log.info("sheep", "[\(id)] Being petted!")
        setState(.petting, 0)
    }

    /// Stop petting — called when cursor leaves.
    func stopPetting() {
        if state != .petting { return }
        Log.info("sheep", "[\(id)] Petting stopped")
        setState(.idle, 2000 + SimRandom.next() * 3000)
    }

    /// Returns a random quip for double-click interaction.
    func getRandomQuip() -> String {
        let quips = [
            "Hey! Hooves are sensitive!",
            "Do I come to YOUR desktop and poke you?",
            "Baaaa! That tickles!",
            "*startled sheep noises*",
            "I was THINKING. Very deep thoughts.",
            "You know I can see your tabs, right?",
            "Stop poking me and get back to work.",
            "Is this what passes for entertainment?",
            "I'm not a button. I'm a sheep.",
            "If you pet me one more time I'm filing an HR complaint.",
            "Wow, procrastinating by clicking on a sheep. New low.",
            "I'm judging you. Always judging.",
            "That's my personal space!",
            "Ow! Just kidding, I'm made of pixels.",
        ]
        return quips[SimRandom.int(quips.count)]
    }

    /// Start stampede — scatter away from the given X coordinate
    func startStampede(_ mouseX: Double) {
        if state == .parachute || state == .stacked { return }
        // Unstack if involved in a stack
        if let by = stackedBy {
            by.stackedOn = nil
            by.setState(.stampede, 1500)
            by.facingRight = SimRandom.next() > 0.5
            stackedBy = nil
        }
        if let on = stackedOn {
            on.stackedBy = nil
            stackedOn = nil
        }
        currentPlatform = nil
        resetActivity()
        setState(.stampede, 1200 + SimRandom.next() * 800)
        // Run AWAY from mouse
        facingRight = x > mouseX
        // If too close to edge, run the other way
        if !facingRight && x < 100 { facingRight = true }
        if facingRight && x > screenWidth - 100 { facingRight = false }
    }

    /// Start trampoline bouncing — called when dropped from very high
    func startTrampoline() {
        setState(.trampoline, 12000) // max 12s
        trampolineBounces = 0
        trampolineFlipProgress = 0
        vy = 0 // gravity will do the work
    }

    /// Stack this sheep on top of another
    func stackOn(_ other: Sheep) {
        stackedOn = other
        other.stackedBy = self
        setState(.stacked, 0)
        // Position on top
        x = other.x + (other.displaySize - displaySize) / 2
        y = other.y - displaySize * 0.7
        facingRight = other.facingRight
    }

    /// Unstack this sheep from whatever it's stacked on
    func unstack() {
        if let on = stackedOn {
            on.stackedBy = nil
            stackedOn = nil
        }
    }

    /// Fully detach from any stack, in both directions — used when this
    /// sheep is removed from the flock so nobody tracks a ghost.
    func detachFromStack() {
        if let by = stackedBy {
            by.stackedOn = nil
            by.vy = -150
            by.setState(.fall, 0)
            stackedBy = nil
        }
        unstack()
    }

    /// Re-align with the ground after a screen resize — grounded states
    /// never touch y themselves, so they'd float or sink otherwise.
    func reground() {
        x = max(0, min(x, screenWidth - displaySize))
        let airborne: [SheepState] = [.grabbed, .parachute, .fall, .trampoline, .stacked, .bounce, .backflip]
        if airborne.contains(state) { return }
        if currentPlatform != nil { return } // platform validity check handles this
        y = groundY
    }

    /// Called when the platform this sheep is standing on disappears
    func loseGround() {
        if state == .grabbed || state == .parachute || state == .fall || state == .trampoline { return }
        currentPlatform = nil
        state = .parachute
        stateTimer = 0
        vy = 0
        if let sprite = sprites["parachute"] { sprite.reset() }
    }

    /// Hit-test: is point (px, py) over the sheep? Uses a generous hitbox.
    func hitTest(_ px: Double, _ py: Double) -> Bool {
        let pad = 12.0
        let ds = displaySize
        return px >= x - pad &&
            px <= x + ds + pad &&
            py >= y - pad &&
            py <= y + ds + pad
    }

    // MARK: Update

    func update(_ dt: Double) {
        stateTimer += dt

        // Animate sprite — pick the right sheet for the current state
        let spriteKey = getSpriteKey()
        if let currentSprite = sprites[spriteKey] { currentSprite.update(dt) }

        // While the human is chatting, park in "sit" once any physics state
        // or reply animation has finished
        if listening && state != .sit && Self.LISTENING_PARKABLE.contains(state) {
            setState(.sit, 0)
        }

        switch state {
        case .parachute:
            updateParachute(dt)
        case .idle:
            updateIdle()
        case .walk:
            updateWalk(dt)
        case .sit:
            if !listening { updateSit() }
        case .sleep:
            updateSleep()
        case .fall:
            updateFall(dt)
        case .grabbed:
            x = max(0, min(x, screenWidth - displaySize))
            y = max(0, min(y, screenHeight - displaySize))
        case .petting:
            // Just chill — sprite animation handles the rest
            break
        case .bounce:
            updateBounce(dt)
        case .spin, .backflip, .headshake, .vibrate:
            updateTimedAnimation()
        case .zoom:
            updateZoom(dt)
        case .idleSleep:
            updateIdleSleep()
        case .idleCampfire:
            updateIdleCampfire(dt)
        case .idleCounting:
            updateIdleCounting()
        case .idleJudging:
            updateIdleJudging()
        case .idleHearts:
            updateIdleHearts()
        case .idleZooming:
            updateIdleZooming(dt)
        case .idleSighing:
            updateIdleSighing()
        case .idleEggPainting:
            updateIdleEggPainting()
        case .stampede:
            updateStampede(dt)
        case .trampoline:
            updateTrampoline(dt)
        case .stacked:
            updateStacked()
        }

        // Check platform validity (if standing on a window that moved/closed)
        if let p = currentPlatform, state != .grabbed, state != .parachute,
           state != .fall, state != .trampoline, state != .stampede {
            let found = platforms.contains { wp in
                abs(wp.x - p.x) < 30 && abs(wp.y - p.y) < 30 && abs(wp.w - p.w) < 30
            }
            if !found {
                loseGround()
            }
        }
    }

    private func setState(_ newState: SheepState, _ duration: Double = 0) {
        if newState == .idleEggPainting {
            eggPaintingRegistered = false
        } else if state == .idleEggPainting {
            eggPaintingRegistered = false
        }
        state = newState
        stateTimer = 0
        stateDuration = duration
        if let sprite = sprites[newState.rawValue] { sprite.reset() }
    }

    private func updateParachute(_ dt: Double) {
        vy = 80 // slow fall px/sec
        y += vy * (dt / 1000)

        // Gentle side-to-side sway
        x += sin(stateTimer / 500) * 0.5

        // Check platform landing first
        if checkPlatformLanding() {
            vy = 0
            setState(.idle, 2000 + SimRandom.next() * 3000)
            return
        }

        if y >= groundY {
            y = groundY
            vy = 0
            currentPlatform = nil
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdle() {
        if stateTimer >= stateDuration {
            transitionFromIdle()
        }
    }

    private func updateWalk(_ dt: Double) {
        let dir: Double = facingRight ? 1 : -1
        x += dir * walkSpeed * (dt / 1000)

        // If on a window platform, check boundaries
        if let p = currentPlatform {
            if x < p.x - displaySize * 0.3 || x + displaySize > p.x + p.w + displaySize * 0.3 {
                // Walked off the edge! Fall with parachute
                currentPlatform = nil
                state = .parachute
                stateTimer = 0
                vy = 0
                if let sprite = sprites["parachute"] { sprite.reset() }
                return
            }
        }

        if x <= 0 {
            x = 0
            facingRight = true
        } else if x >= screenWidth - displaySize {
            x = screenWidth - displaySize
            facingRight = false
        }

        // Check if we've reached our walk target
        if let target = walkTarget {
            let dist = abs(x - target)
            if dist < displaySize * 1.5 {
                walkTarget = nil
                // Arrived near target — sit down together or idle
                if SimRandom.next() < 0.5 {
                    setState(.sit, 5000 + SimRandom.next() * 8000)
                } else {
                    setState(.idle, 2000 + SimRandom.next() * 4000)
                }
                return
            }
        }

        if stateTimer >= stateDuration {
            walkTarget = nil
            setState(.idle, 2000 + SimRandom.next() * 6000)
        }
    }

    private func updateSit() {
        if stateTimer >= stateDuration {
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func updateSleep() {
        if stateTimer >= stateDuration {
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func updateFall(_ dt: Double) {
        vy += 800 * (dt / 1000)
        y += vy * (dt / 1000)

        if checkPlatformLanding() {
            vy = 0
            setState(.idle, 1000 + SimRandom.next() * 2000)
            return
        }

        if y >= groundY {
            y = groundY
            vy = 0
            currentPlatform = nil
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func transitionFromIdle() {
        if isBored() {
            transitionToBored()
            return
        }

        // If we have a walk target, walk toward it with enough time to arrive
        if let target = walkTarget {
            facingRight = target > x
            let dist = abs(target - x)
            let duration = max(3000, (dist / walkSpeed) * 1000 + 2000)
            setState(.walk, duration)
            return
        }

        let w = getIdleWeights()
        let roll = SimRandom.next()
        if roll < w.walk {
            facingRight = SimRandom.next() > 0.5
            setState(.walk, 3000 + SimRandom.next() * 7000)
        } else if roll < w.walk + w.sit {
            setState(.sit, 5000 + SimRandom.next() * 10000)
        } else if roll < w.walk + w.sit + w.sleep {
            setState(.sleep, 8000 + SimRandom.next() * 12000)
        } else {
            setState(.idle, 2000 + SimRandom.next() * 6000)
        }
    }

    private func getIdleWeights() -> (walk: Double, sit: Double, sleep: Double) {
        let hour = SimClock.hour()
        if hour >= 23 || hour <= 4 { return (0.2, 0.3, 0.3) }
        if hour >= 6 && hour <= 8 { return (0.8, 0.1, 0.0) }
        if hour >= 13 && hour <= 14 { return (0.4, 0.35, 0.1) }
        if hour >= 18 && hour <= 21 { return (0.45, 0.3, 0.05) }
        return (0.7, 0.2, 0.0)
    }

    private func transitionToBored() {
        // Ensure campfire has room — face away from nearest edge
        if x < displaySize * 2 {
            facingRight = true
        } else if x > screenWidth - displaySize * 3 {
            facingRight = false
        }

        // Personality-specific bored behaviors for friends
        if personality != nil {
            transitionToPersonalityBored()
            return
        }

        // Easter egg painting chance during Easter season
        if easterTheme?.active == true && SimRandom.next() < 0.15 {
            setState(.idleEggPainting, 12000 + SimRandom.next() * 8000)
            return
        }

        let bw = getBoredWeights()
        let roll = SimRandom.next()
        if roll < bw.sleep {
            setState(.idleSleep, 15000 + SimRandom.next() * 15000)
        } else if roll < bw.sleep + bw.campfire {
            campfireSparks = []
            setState(.idleCampfire, 15000 + SimRandom.next() * 10000)
        } else {
            setState(.idleCounting, 10000 + SimRandom.next() * 5000)
        }
    }

    private func transitionToPersonalityBored() {
        // Easter egg painting chance during Easter season
        if easterTheme?.active == true && SimRandom.next() < 0.15 {
            setState(.idleEggPainting, 12000 + SimRandom.next() * 8000)
            return
        }

        let roll = SimRandom.next()
        switch personality {
        case .chaotic?:
            if roll < 0.4 { setState(.idleZooming, 8000 + SimRandom.next() * 6000) }
            else if roll < 0.7 { campfireSparks = []; setState(.idleCampfire, 12000 + SimRandom.next() * 8000) }
            else if roll < 0.9 { setState(.idleCounting, 8000 + SimRandom.next() * 5000) }
            else { setState(.idleSleep, 10000 + SimRandom.next() * 10000) }
        case .wholesome?:
            if roll < 0.4 { setState(.idleHearts, 10000 + SimRandom.next() * 8000) }
            else if roll < 0.7 { setState(.idleSleep, 12000 + SimRandom.next() * 12000) }
            else if roll < 0.9 { campfireSparks = []; setState(.idleCampfire, 12000 + SimRandom.next() * 8000) }
            else { setState(.idleCounting, 8000 + SimRandom.next() * 5000) }
        case .snarky?:
            if roll < 0.4 { setState(.idleJudging, 10000 + SimRandom.next() * 8000) }
            else if roll < 0.7 { setState(.idleCounting, 8000 + SimRandom.next() * 5000) }
            else if roll < 0.9 { campfireSparks = []; setState(.idleCampfire, 12000 + SimRandom.next() * 8000) }
            else { setState(.idleSleep, 10000 + SimRandom.next() * 10000) }
        case .passiveAggressive?:
            if roll < 0.4 { setState(.idleSighing, 10000 + SimRandom.next() * 8000) }
            else if roll < 0.7 { setState(.idleSleep, 12000 + SimRandom.next() * 12000) }
            else if roll < 0.9 { campfireSparks = []; setState(.idleCampfire, 12000 + SimRandom.next() * 8000) }
            else { setState(.idleCounting, 8000 + SimRandom.next() * 5000) }
        case nil:
            campfireSparks = []
            setState(.idleCampfire, 12000 + SimRandom.next() * 8000)
        }
    }

    private func getBoredWeights() -> (sleep: Double, campfire: Double, counting: Double) {
        let hour = SimClock.hour()
        if hour >= 23 || hour <= 4 { return (0.7, 0.1, 0.2) }
        if hour >= 18 && hour <= 21 { return (0.2, 0.55, 0.25) }
        return (0.4, 0.35, 0.25)
    }

    private func updateIdleSleep() {
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleCampfire(_ dt: Double) {
        // Spawn sparks occasionally
        if SimRandom.next() < 0.03 {
            let fireX = facingRight
                ? x + displaySize + 10
                : x - 25
            campfireSparks.append(CampfireSpark(
                x: fireX + 5 + SimRandom.next() * 10,
                y: groundY + displaySize * 0.7,
                life: 1.0
            ))
        }
        // Update sparks
        var alive: [CampfireSpark] = []
        for var s in campfireSparks {
            s.y -= 30 * (dt / 1000)
            s.x += (SimRandom.next() - 0.5) * 20 * (dt / 1000)
            s.life -= 1.5 * (dt / 1000)
            if s.life > 0 { alive.append(s) }
        }
        campfireSparks = alive

        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleCounting() {
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleJudging() {
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleHearts() {
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleZooming(_ dt: Double) {
        // Every ~3s, do a brief zoom burst
        let cycle = stateTimer.truncatingRemainder(dividingBy: 3000)
        if cycle < 300 {
            if !idleZoomBurst {
                idleZoomBurst = true
                facingRight = SimRandom.next() > 0.5
            }
            let dir: Double = facingRight ? 1 : -1
            x += dir * 400 * (dt / 1000)
            // Clamp to screen
            if x <= 0 { x = 0; facingRight = true }
            else if x >= screenWidth - displaySize {
                x = screenWidth - displaySize
                facingRight = false
            }
        } else if idleZoomBurst {
            idleZoomBurst = false
        }

        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleSighing() {
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateIdleEggPainting() {
        if !eggPaintingRegistered && stateDuration > 2000 && stateTimer >= stateDuration - 1800 {
            easterTheme?.registerPaintedEgg(id, name)
            eggPaintingRegistered = true
        }
        if stateTimer >= stateDuration {
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateStampede(_ dt: Double) {
        let dir: Double = facingRight ? 1 : -1
        let speed = Self.ZOOM_SPEED * 1.5
        x += dir * speed * (dt / 1000)

        if x <= 0 {
            x = 0
            endStampede()
            return
        }
        if x >= screenWidth - displaySize {
            x = screenWidth - displaySize
            endStampede()
            return
        }

        if stateTimer >= stateDuration {
            endStampede()
        }
    }

    /// Stampede only moves x — a sheep that stampeded off a platform (or
    /// while airborne) must fall afterwards, not hover where it ended up.
    private func endStampede() {
        if y < groundY - 1 {
            vy = 0
            setState(.fall, 0)
        } else {
            y = groundY
            setState(.idle, 2000 + SimRandom.next() * 3000)
        }
    }

    private func updateTrampoline(_ dt: Double) {
        let GRAVITY = 1200.0
        let BOUNCE_DAMPING = 0.68
        let MAX_BOUNCES = 5
        let MIN_BOUNCE_VEL = 120.0

        vy += GRAVITY * (dt / 1000)
        y += vy * (dt / 1000)

        // Flip while airborne
        if y < groundY {
            trampolineFlipProgress += dt / 350
        }

        if y >= groundY {
            y = groundY
            trampolineBounces += 1
            trampolineFlipProgress = 0

            if trampolineBounces >= MAX_BOUNCES || abs(vy) * BOUNCE_DAMPING < MIN_BOUNCE_VEL {
                vy = 0
                setState(.idle, 1000 + SimRandom.next() * 2000)
                return
            }

            // Bounce!
            vy = -abs(vy) * BOUNCE_DAMPING
        }

        if stateTimer >= stateDuration {
            y = groundY
            vy = 0
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func updateStacked() {
        guard let target = stackedOn else {
            vy = -100
            setState(.fall, 0)
            return
        }

        x = target.x + (target.displaySize - displaySize) / 2
        y = target.y - displaySize * 0.7
        facingRight = target.facingRight

        // Unstack if bottom sheep enters a wild state
        if target.state == .stampede || target.state == .zoom || target.state == .grabbed
            || target.state == .trampoline || target.state == .backflip {
            unstack()
            vy = -200
            setState(.fall, 0)
        }
    }

    /// Check if the sheep should land on a window platform during fall/parachute
    private func checkPlatformLanding() -> Bool {
        for p in platforms {
            let landY = p.y - displaySize
            // Only land on platforms that are above the ground
            if landY >= groundY { continue }
            // ...but low enough that the sheep stays fully on-screen — a
            // maximized window's top edge sits at the menu bar
            if landY < 0 { continue }
            if y >= landY && y - 10 < landY + 20 {
                if x + displaySize > p.x && x < p.x + p.w {
                    y = landY
                    currentPlatform = p
                    return true
                }
            }
        }
        return false
    }

    /// Map states to sprite sheet keys
    private func getSpriteKey() -> String {
        switch state {
        case .grabbed: "fall"
        case .petting: "sleep"
        case .bounce: "idle"
        case .spin: "walk"
        case .backflip: "fall"
        case .headshake: "idle"
        case .zoom: "walk"
        case .vibrate: "idle"
        case .idleSleep: "sleep"
        case .idleCampfire: "sit"
        case .idleCounting: "idle"
        case .idleJudging: "idle"
        case .idleHearts: "sit"
        case .idleZooming: "walk"
        case .idleSighing: "sit"
        case .idleEggPainting: "sit"
        case .stampede: "walk"
        case .trampoline: "fall"
        case .stacked: "sit"
        default: state.rawValue
        }
    }

    private func updateBounce(_ dt: Double) {
        vy += 800 * (dt / 1000) // gravity
        y += vy * (dt / 1000)

        // Land back on the platform we bounced from, not through it
        if y >= effectiveGroundY {
            y = effectiveGroundY
            if stateTimer >= stateDuration {
                setState(.idle, 1000 + SimRandom.next() * 2000)
            } else {
                vy = -200 // smaller re-bounce
            }
        }
    }

    private func updateTimedAnimation() {
        if stateTimer >= stateDuration {
            // Settle on the current platform if standing on one — snapping to
            // the global ground would teleport the sheep off its window
            y = effectiveGroundY
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    private func updateZoom(_ dt: Double) {
        let dir: Double = facingRight ? 1 : -1
        x += dir * Self.ZOOM_SPEED * (dt / 1000)

        // Bounce off edges
        if x <= 0 {
            x = 0
            facingRight = true
        } else if x >= screenWidth - displaySize {
            x = screenWidth - displaySize
            facingRight = false
        }

        if stateTimer >= stateDuration {
            setState(.idle, 1000 + SimRandom.next() * 2000)
        }
    }

    // MARK: Draw

    func draw(_ ctx: Canvas) {
        let spriteKey = getSpriteKey()
        guard let sprite = sprites[spriteKey] else { return }

        let cx = x + displaySize / 2
        let cy = y + displaySize / 2
        let t = tint

        switch state {
        case .grabbed:
            let wiggle = sin(stateTimer / 60) * 0.18
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(wiggle)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .petting:
            // Gentle happy sway
            let sway = sin(stateTimer / 300) * 0.05
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(sway)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .bounce:
            // Squash and stretch based on vertical velocity
            let squash = 1 + abs(vy) * 0.001
            let scaleX = 1 / squash
            let scaleY = squash
            ctx.save()
            ctx.translate(cx, y + displaySize)
            ctx.scale(scaleX, scaleY)
            ctx.translate(-cx, -(y + displaySize))
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .spin:
            let angle = (stateTimer / stateDuration) * .pi * 2
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(angle)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .backflip:
            let progress = stateTimer / stateDuration
            let angle = progress * .pi * 2
            // Arc up then down
            let arcY = y - sin(progress * .pi) * 80
            let arcCy = arcY + displaySize / 2
            ctx.save()
            ctx.translate(cx, arcCy)
            ctx.rotate(-angle)
            ctx.translate(-cx, -arcCy)
            sprite.draw(ctx, x, arcY, drawScale, !facingRight, t)
            ctx.restore()

        case .headshake:
            let shake = sin(stateTimer / 30) * 8
            ctx.save()
            ctx.translate(shake, 0)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .zoom:
            // Lean forward + motion blur via slight horizontal stretch
            let lean = facingRight ? -0.2 : 0.2
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(lean)
            ctx.scale(1.15, 0.9)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)

            // Speed lines (afterimages)
            ctx.globalAlpha = 0.15
            let trailDir: Double = facingRight ? -1 : 1
            sprite.draw(ctx, x + trailDir * 30, y, drawScale, !facingRight, t)
            ctx.globalAlpha = 0.07
            sprite.draw(ctx, x + trailDir * 60, y, drawScale, !facingRight, t)
            ctx.restore()

        case .vibrate:
            let ox = (SimRandom.next() - 0.5) * 6
            let oy = (SimRandom.next() - 0.5) * 6
            sprite.draw(ctx, x + ox, y + oy, drawScale, !facingRight, t)

        case .stampede:
            // Heavy lean forward + aggressive speed lines
            let stampLean = facingRight ? -0.25 : 0.25
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(stampLean)
            ctx.scale(1.2, 0.85)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            let stampTrail: Double = facingRight ? -1 : 1
            ctx.globalAlpha = 0.2
            sprite.draw(ctx, x + stampTrail * 25, y, drawScale, !facingRight, t)
            ctx.globalAlpha = 0.1
            sprite.draw(ctx, x + stampTrail * 50, y, drawScale, !facingRight, t)
            ctx.globalAlpha = 0.05
            sprite.draw(ctx, x + stampTrail * 75, y, drawScale, !facingRight, t)
            ctx.restore()

        case .trampoline:
            // Squash/stretch + flip rotation
            let tSquash = 1 + abs(vy) * 0.0006
            let tScaleX = 1 / tSquash
            let tScaleY = tSquash
            let flipAngle = trampolineFlipProgress * .pi * 2
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(flipAngle)
            ctx.scale(tScaleX, tScaleY)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        case .stacked:
            // Gentle wobble
            let wobble = sin(stateTimer / 300) * 0.08
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(wobble)
            ctx.translate(-cx, -cy)
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
            ctx.restore()

        default:
            sprite.draw(ctx, x, y, drawScale, !facingRight, t)
        }

        // Draw emote particles for certain animations
        drawEmoteParticles(ctx)

        // Draw character-specific overlay (accessories etc.)
        if let drawOverlay {
            drawOverlay(ctx, x, y, displaySize, facingRight, state)
        }
        if let seasonalOverlay {
            seasonalOverlay(ctx, x, y, displaySize, facingRight, state)
        }

        // Name tag for non-main sheep during calm states
        if id != "main" && name != "Sheep" {
            let calm = state == .idle || state == .sit || state == .walk
                || state == .sleep || state == .petting
            if calm && nameTagAlpha < 1 {
                nameTagAlpha = min(1, nameTagAlpha + 0.05)
            } else if !calm && nameTagAlpha > 0 {
                nameTagAlpha = max(0, nameTagAlpha - 0.05)
            }
            if nameTagAlpha > 0 {
                let ds = displaySize
                let tagCx = x + ds / 2
                let tagY = y + ds + 14
                ctx.save()
                ctx.globalAlpha = nameTagAlpha * 0.7
                ctx.font = "10px monospace"
                let tw = ctx.measureText(name).width
                ctx.fillStyle = "rgba(26, 26, 46, 0.6)"
                ctx.beginPath()
                ctx.roundRect(tagCx - tw / 2 - 4, tagY - 9, tw + 8, 14, 3)
                ctx.fill()
                ctx.fillStyle = "#ccc"
                ctx.globalAlpha = nameTagAlpha * 0.9
                ctx.textAlign = "center"
                ctx.fillText(name, tagCx, tagY)
                ctx.restore()
            }
        }
    }

    /// The campfire and the egg-painting table are drawn at `groundY`, not at
    /// the sheep. When the sheep is up on a window platform that is far away,
    /// so those go into their own tile instead of stretching the sheep's tile
    /// down to the ground (the campfire flickers every frame).
    private func drawAtGround(_ ctx: Canvas, _ body: () -> Void) {
        if abs(groundY - y) > displaySize {
            ctx.group("sheep:\(id):ground", layer: .world, body)
        } else {
            body()
        }
    }

    private func drawEmoteParticles(_ ctx: Canvas) {
        let cx = x + displaySize / 2
        let top = y - 10

        if state == .petting {
            // Floating hearts
            ctx.save()
            ctx.font = "14px serif"
            let t = stateTimer / 600
            let heartCount = 3
            for i in 0..<heartCount {
                let phase = t + Double(i) * 2.1
                let hx = cx + sin(phase * 1.5) * 25 - 8
                let hy = top - phase.truncatingRemainder(dividingBy: 3) * 20
                ctx.globalAlpha = 1 - phase.truncatingRemainder(dividingBy: 3) / 3
                ctx.fillText("\u{2764}\u{FE0F}", hx, hy)
            }
            ctx.restore()
        }

        if state == .bounce && vy < -50 {
            // Sparkles on upward bounce
            ctx.save()
            ctx.fillStyle = "#FFD700"
            ctx.font = "16px serif"
            let sparkleY = top - sin(stateTimer / 100) * 15
            ctx.fillText("\u{2728}", cx - 20, sparkleY)
            ctx.fillText("\u{2728}", cx + 10, sparkleY - 8)
            ctx.restore()
        }

        if state == .vibrate {
            // Angry marks
            ctx.save()
            ctx.fillStyle = "#e94560"
            ctx.font = "18px serif"
            let pulse = 0.8 + sin(stateTimer / 50) * 0.2
            ctx.globalAlpha = pulse
            ctx.fillText("\u{1F4A2}", cx - 8, top - 5)
            ctx.restore()
        }

        if state == .idleSleep {
            drawSleepZzz(ctx, cx, top)
        }

        if state == .idleCampfire {
            drawAtGround(ctx) { drawCampfire(ctx) }
        }

        if state == .idleCounting {
            drawCountingSheep(ctx, cx, top)
        }

        if state == .idleJudging {
            drawJudging(ctx, cx, top)
        }

        if state == .idleHearts {
            drawIdleHearts(ctx, cx, top)
        }

        if state == .idleZooming && idleZoomBurst {
            // Speed lines during zoom bursts
            ctx.save()
            ctx.strokeStyle = "rgba(233, 69, 96, 0.3)"
            ctx.lineWidth = 1
            let dir: Double = facingRight ? -1 : 1
            for i in 0..<3 {
                let ly = y + 20 + Double(i) * 25
                ctx.beginPath()
                ctx.moveTo(cx + dir * 20, ly)
                ctx.lineTo(cx + dir * 50, ly + (SimRandom.next() - 0.5) * 4)
                ctx.stroke()
            }
            ctx.restore()
        }

        if state == .idleSighing {
            drawSighing(ctx, cx, top)
        }

        if state == .idleEggPainting {
            drawAtGround(ctx) { drawEggPainting(ctx) }
        }

        if state == .stampede {
            // Panic exclamation marks
            ctx.save()
            ctx.font = "bold 16px monospace"
            ctx.fillStyle = "#e94560"
            let panic = sin(stateTimer / 80) * 4
            ctx.globalAlpha = 0.8
            ctx.fillText("!", cx - 4 + panic, top - 8)
            ctx.fillText("!", cx + 8 - panic, top - 14)
            ctx.restore()
        }

        if state == .trampoline {
            // "BOING" on bounce (when near ground and going up)
            if vy < -100 && y > groundY - 60 {
                ctx.save()
                ctx.font = "bold 12px monospace"
                ctx.fillStyle = "#FFD700"
                ctx.globalAlpha = 0.9
                ctx.fillText("BOING!", cx - 20, top - 10)
                ctx.restore()
            }
            // Sparkles while airborne
            if y < groundY - 30 {
                ctx.save()
                ctx.fillStyle = "#FFD700"
                ctx.font = "14px serif"
                let sparkT = stateTimer / 150
                ctx.globalAlpha = 0.6
                ctx.fillText("\u{2728}", cx - 25 + sin(sparkT) * 10, top - 5)
                ctx.fillText("\u{2728}", cx + 15 + cos(sparkT) * 8, top + 10)
                ctx.restore()
            }
        }

        if state == .stacked {
            // Balancing wobble indicator
            let wobbleT = stateTimer / 500
            if sin(wobbleT * 2) > 0.7 {
                ctx.save()
                ctx.font = "10px monospace"
                ctx.fillStyle = "rgba(233, 69, 96, 0.5)"
                ctx.fillText("~", cx + displaySize * 0.3, top + 5)
                ctx.restore()
            }
        }
    }

    private func drawSleepZzz(_ ctx: Canvas, _ cx: Double, _ top: Double) {
        ctx.save()
        let t = stateTimer / 1000
        for i in 0..<3 {
            let phase = (t * 0.6 + Double(i) * 1.4).truncatingRemainder(dividingBy: 4)
            let zx = cx + 12 + Double(i) * 10 + sin(phase * 1.8) * 8
            let zy = top - phase * 16
            let size = 11 + i * 4
            ctx.globalAlpha = max(0, 1 - phase / 4)
            ctx.font = "bold \(size)px monospace"
            ctx.fillStyle = "#8a9bb5"
            ctx.fillText("Z", zx, zy)
        }
        ctx.restore()
    }

    private func drawCampfire(_ ctx: Canvas) {
        let fireX = facingRight
            ? x + displaySize + 8
            : x - 28
        let baseY = groundY + displaySize - 8

        // Logs
        ctx.fillStyle = "#6B3A2A"
        ctx.fillRect(fireX, baseY + 2, 20, 5)
        ctx.fillStyle = "#8B4513"
        ctx.fillRect(fireX + 3, baseY - 2, 14, 5)

        // Fire — flickering pixel flames
        let t = stateTimer / 120
        let flicker1 = sin(t) * 2
        let flicker2 = cos(t * 1.3) * 2

        // Outer flame (orange-red)
        ctx.fillStyle = "#E8530E"
        ctx.fillRect(fireX + 4, baseY - 10 + flicker1, 12, 12)
        // Mid flame (orange)
        ctx.fillStyle = "#FF8C00"
        ctx.fillRect(fireX + 6, baseY - 14 + flicker2, 8, 10)
        // Inner flame (yellow)
        ctx.fillStyle = "#FFD700"
        ctx.fillRect(fireX + 8, baseY - 16 + flicker1 * 0.7, 5, 7)
        // Hot core (white-yellow)
        ctx.fillStyle = "#FFF4C0"
        ctx.fillRect(fireX + 9, baseY - 12 + flicker2 * 0.5, 3, 4)

        // Sparks
        ctx.fillStyle = "#FFD700"
        for spark in campfireSparks {
            ctx.globalAlpha = spark.life
            ctx.fillRect(spark.x, spark.y, 2, 2)
        }
        ctx.globalAlpha = 1

        // Warm glow
        ctx.save()
        let gradient = ctx.createRadialGradient(
            fireX + 10, baseY - 6, 3,
            fireX + 10, baseY - 6, 50
        )
        gradient.addColorStop(0, "rgba(255, 150, 50, 0.12)")
        gradient.addColorStop(1, "rgba(255, 150, 50, 0)")
        ctx.fillStyle = gradient
        ctx.beginPath()
        ctx.arc(fireX + 10, baseY - 6, 50, 0, .pi * 2)
        ctx.fill()
        ctx.restore()
    }

    private func drawCountingSheep(_ ctx: Canvas, _ cx: Double, _ top: Double) {
        let elapsed = stateTimer / 1000
        let sheepCount = Int((elapsed / 2.5).rounded(.down)) // One every 2.5s

        for i in stride(from: 0, through: min(sheepCount, 6), by: 1) {
            let t = elapsed - Double(i) * 2.5
            if t < 0 { continue }
            let loopT = t.truncatingRemainder(dividingBy: 3)
            if loopT > 2.8 { continue } // brief gap between loops

            let progress = loopT / 2.8
            let miniX = cx - 35 + progress * 70
            let arcHeight = sin(progress * .pi) * 45
            let miniY = top - 15 - arcHeight

            ctx.save()
            ctx.globalAlpha = 0.8
            // Mini sheep body (white fluffy blob)
            ctx.fillStyle = "#F0F0F0"
            ctx.fillRect(miniX, miniY, 9, 6)
            // Head
            ctx.fillStyle = "#444"
            ctx.fillRect(miniX + 7, miniY - 2, 3, 4)
            // Legs (animate based on progress)
            let legBob: Double = sin(progress * .pi * 4) > 0 ? 0 : 1
            ctx.fillRect(miniX + 1, miniY + 6, 2, 2 + legBob)
            ctx.fillRect(miniX + 5, miniY + 6, 2, 2 + (1 - legBob))
            ctx.restore()
        }

        // Counter bubble
        if sheepCount > 0 {
            ctx.save()
            ctx.font = "bold 11px monospace"
            ctx.fillStyle = "rgba(180, 190, 210, 0.7)"
            ctx.fillText("\(min(sheepCount, 99))", cx + 30, top - 50)
            ctx.restore()
        }
    }

    private func drawJudging(_ ctx: Canvas, _ cx: Double, _ top: Double) {
        ctx.save()
        let t = stateTimer / 1000
        // Floating magnifying glass that slowly sways
        let mx = cx + sin(t * 0.8) * 12
        let my = top - 15 + sin(t * 1.2) * 4
        ctx.globalAlpha = 0.7
        // Glass circle
        ctx.strokeStyle = "#DAA520"
        ctx.lineWidth = 2
        ctx.beginPath()
        ctx.arc(mx, my, 7, 0, .pi * 2)
        ctx.stroke()
        // Lens shine
        ctx.fillStyle = "rgba(180, 220, 255, 0.15)"
        ctx.beginPath()
        ctx.arc(mx, my, 6, 0, .pi * 2)
        ctx.fill()
        // Handle
        ctx.strokeStyle = "#8B4513"
        ctx.lineWidth = 2.5
        ctx.beginPath()
        ctx.moveTo(mx + 5, my + 5)
        ctx.lineTo(mx + 12, my + 12)
        ctx.stroke()
        // Occasional subtle headshake offset
        if sin(t * 2) > 0.8 {
            ctx.font = "bold 10px monospace"
            ctx.fillStyle = "rgba(233, 69, 96, 0.5)"
            ctx.fillText("hmm", cx + 20, top - 25)
        }
        ctx.restore()
    }

    private func drawIdleHearts(_ ctx: Canvas, _ cx: Double, _ top: Double) {
        ctx.save()
        ctx.font = "12px serif"
        let t = stateTimer / 1000
        for i in 0..<2 {
            let phase = (t * 0.4 + Double(i) * 1.8).truncatingRemainder(dividingBy: 3.5)
            let hx = cx + sin(phase * 1.2 + Double(i)) * 20 - 6
            let hy = top - phase * 15
            ctx.globalAlpha = max(0, 0.6 - phase / 3.5)
            ctx.fillText("\u{2764}\u{FE0F}", hx, hy)
        }
        ctx.restore()
    }

    private func drawSighing(_ ctx: Canvas, _ cx: Double, _ top: Double) {
        ctx.save()
        let t = stateTimer / 1000
        // "..." text bubble
        let dotPhase = Int((t * 1.5).rounded(.down)) % 4
        let dots = String(repeating: ".", count: min(dotPhase + 1, 3))
        ctx.font = "bold 14px monospace"
        ctx.fillStyle = "rgba(150, 150, 170, 0.6)"
        ctx.globalAlpha = 0.7 + sin(t) * 0.2
        ctx.fillText(dots, cx - 10, top - 10)
        // Small cloud puffs drifting up
        for i in 0..<2 {
            let pPhase = (t * 0.5 + Double(i) * 1.5).truncatingRemainder(dividingBy: 3)
            let px = cx + 15 + Double(i) * 8 + sin(pPhase + Double(i)) * 5
            let py = top - 20 - pPhase * 12
            ctx.globalAlpha = max(0, 0.3 - pPhase / 3)
            ctx.fillStyle = "#888"
            ctx.beginPath()
            ctx.arc(px, py, 3, 0, .pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    private func drawEggPainting(_ ctx: Canvas) {
        let eggX = facingRight
            ? x + displaySize + 8
            : x - 22
        let baseY = groundY + displaySize - 4
        let progress = min(1, stateTimer / (stateDuration - 2000)) // 0..1

        ctx.save()

        // Egg (white oval)
        ctx.fillStyle = "#FFFFF0"
        ctx.beginPath()
        ctx.ellipse(eggX + 7, baseY - 4, 6, 9, 0, 0, .pi * 2)
        ctx.fill()
        ctx.strokeStyle = "#DDD"
        ctx.lineWidth = 0.5
        ctx.stroke()

        // Progressive paint stripes (appear as progress increases)
        let stripeColors = ["#FFB6C1", "#B0E2AC", "#C8B4E6", "#FFFACD"]
        for i in 0..<4 {
            if progress > Double(i + 1) / 5 {
                ctx.fillStyle = stripeColors[i]
                let sy = baseY - 10 + Double(i) * 4
                ctx.fillRect(eggX + 2, sy, 10, 2)
            }
        }

        // Tiny dots decoration (appear later)
        if progress > 0.7 {
            ctx.fillStyle = "#FFD700"
            ctx.beginPath()
            ctx.arc(eggX + 5, baseY - 6, 1.5, 0, .pi * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.arc(eggX + 9, baseY - 2, 1.5, 0, .pi * 2)
            ctx.fill()
        }

        // Brush (brown line near egg)
        let brushBob = sin(stateTimer / 200) * 2
        ctx.strokeStyle = "#8B4513"
        ctx.lineWidth = 1.5
        ctx.beginPath()
        ctx.moveTo(eggX + 14, baseY - 8 + brushBob)
        ctx.lineTo(eggX + 20, baseY - 16 + brushBob)
        ctx.stroke()
        // Brush tip
        ctx.fillStyle = stripeColors[Int((stateTimer / 800).rounded(.down)) % stripeColors.count]
        ctx.beginPath()
        ctx.arc(eggX + 14, baseY - 8 + brushBob, 2, 0, .pi * 2)
        ctx.fill()

        // Sparkle when done (last 2s)
        if stateTimer > stateDuration - 2000 {
            let sparkAlpha = sin(stateTimer / 100) * 0.5 + 0.5
            ctx.globalAlpha = sparkAlpha
            ctx.fillStyle = "#FFD700"
            ctx.font = "12px serif"
            ctx.fillText("\u{2728}", eggX - 2, baseY - 16)
            ctx.fillText("\u{2728}", eggX + 12, baseY - 14)
        }

        ctx.restore()
    }
}
