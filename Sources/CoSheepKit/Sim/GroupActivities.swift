import Foundation

// Ex-group-activities.ts: rare flock-wide activities (campfire circle, follow
// the leader, sync bounce, huddle, Easter egg hunt, sunbathe, and at Christmas
// walking around the tree and the gift exchange). Pure sim: the activities
// steer sheep by poking their state machine (the TS does the same through
// `as any`) and draw nothing themselves — the Easter eggs come from
// `EasterTheme`, the tree, presents and carol notes from `ChristmasTheme`,
// everything else is the sheep's own draw code.

/// The `{ sheep, bubble, personality? }` record every "look up a character by
/// id" callback returns (ex-anonymous type in group-activities.ts /
/// spectacle-render.ts / flock.ts). `personality` is the raw string
/// ("snarky", "wholesome", …) the AI-chat and egg-hunt code keys on.
struct FlockCharacter {
    let sheep: Sheep
    let bubble: SpeechBubble
    let personality: String?
}

/// `getSheep` in the TS: id → character, nil when the id is gone.
typealias GroupActivityLookup = (String) -> FlockCharacter?

nonisolated enum GroupActivityType: String, CaseIterable, Codable {
    case campfireCircle = "campfire_circle"
    case followLeader = "follow_leader"
    case syncBounce = "sync_bounce"
    case huddle
    case easterEggHunt = "easter_egg_hunt"
    case sunbathe
    /// "Gang rundt juletreet": the flock circles the tree, singing.
    case juletregang
    case giftExchange = "gift_exchange"

    /// The Christmas activities happen at the tree, not where the flock stood.
    var gathersAtTree: Bool { self == .juletregang || self == .giftExchange }
}

nonisolated enum GroupActivityPhase: String, CaseIterable {
    case gathering, performing, celebrating, dispersing
}

nonisolated struct EasterHuntFinder: Equatable {
    var eggsFound: Int
    var goldenEggsFound: Int
}

nonisolated struct EasterHuntSummary: Equatable {
    struct Finder: Equatable {
        var id: String
        var eggsFound: Int
        var goldenEggsFound: Int
    }

    var totalEggs: Int
    var durationMs: Double
    var allCollected: Bool
    var paintedEggsUsed: Int
    var winnerId: String?
    var finders: [Finder]
}

/// One running activity. A class: the TS object is mutated in place by the
/// update functions and read by the Flock between frames.
final class GroupActivity {
    let type: GroupActivityType
    let participants: [String]
    var phase: GroupActivityPhase
    var timer: Double
    var duration: Double
    var centerX: Double
    var leaderId: String?
    var bounceCount: Int?
    // Easter egg hunt state
    var eggAssignments: [String: Int]? // participant id → egg index
    var collectedEggs: Set<Int>?
    var eggReactionTimer: Double?
    var eggFinders: [String: EasterHuntFinder]?
    var huntSummary: EasterHuntSummary?
    // Sunbathe state: countdown to the next lazy quip
    var quipTimer: Double?
    // Juletregang state: countdown to the next sung line / drifting note,
    // and how many lines were sung so far
    var carolTimer: Double?
    var noteTimer: Double?
    var carolCount: Int?
    // Gift exchange state
    var giftAssignments: [String: Int]? // participant id → present index
    var giftsOpened: Int?

    init(type: GroupActivityType, participants: [String], phase: GroupActivityPhase, timer: Double,
         duration: Double, centerX: Double) {
        self.type = type
        self.participants = participants
        self.phase = phase
        self.timer = timer
        self.duration = duration
        self.centerX = centerX
    }
}

/// File-level constants of group-activities.ts, scoped so they cannot collide
/// with same-named constants in other files.
nonisolated enum GroupActivityData {
    static let DISPLAY_SIZE: Double = 96
    static let EGG_COLLECTION_RADIUS: Double = DISPLAY_SIZE * 0.35

    static let EGG_HUNT_QUIPS = [
        "Found one!",
        "Egg-cellent!",
        "This one's mine!",
        "Over here!",
        "Got it!",
    ]

    static let EGG_HUNT_PERSONALITY_QUIPS: [String: [String]] = [
        "snarky": ["These eggs are poorly hidden.", "Amateur hour.", "I found it first, obviously."],
        "wholesome": ["Best. Easter. Ever!", "What a pretty egg!", "This is so fun!"],
        "chaotic": ["EGG EGG EGG EGG", "THE EGG CHOSE ME", "I AM THE EGG LORD"],
        "passive-aggressive": ["Oh, I found one. How... delightful.", "I suppose someone had to find it.", "How nice for me."],
        "good_colleague": ["Fint egg, ja", "Påskeegg!", "Nå snakker vi"],
    ]

    static let EGG_HUNT_VICTORY_LINES = [
        "All eggs found!",
        "Spring sweep complete!",
        "The meadow has been cleared!",
    ]

    static let EGG_HUNT_WINNER_LINES = [
        "I carried this hunt.",
        "You're welcome, everyone.",
        "I deserve the golden grass.",
    ]

    // Juletregang: how far to either side of the tree the ring reaches
    static let TREE_RING_RADIUS: Double = DISPLAY_SIZE * 1.6
    /// A straggler further than this from the tree walks in before it joins.
    static let TREE_GATHER_TIMEOUT_MS: Double = 20000
    static let PRESENT_OPEN_RADIUS: Double = DISPLAY_SIZE * 0.35

    /// First lines of the old songs for walking around the tree.
    static let CAROL_LINES = [
        "\u{266A} Så går vi rundt om en enebærbusk \u{266A}",
        "\u{266A} O jul med din glede \u{266A}",
        "\u{266A} På låven sitter nissen \u{266A}",
        "\u{266A} Jeg gikk meg over sjø og land \u{266A}",
        "\u{266A} Du grønne, glitrende tre, god dag \u{266A}",
        "\u{266A} Jeg er så glad hver julekveld \u{266A}",
    ]

    /// What a sheep mutters between the verses.
    static let CAROL_ASIDES: [String: [String]] = [
        "snarky": ["I'm lip-syncing. Nobody tell.", "How many verses does this HAVE?", "We've passed this branch nine times."],
        "wholesome": ["Everyone together now!", "This is my favorite part!", "Sing louder, I love it!"],
        "chaotic": ["FASTER! SPIN THE TREE!", "I'M GOING THE WRONG WAY ON PURPOSE", "BAAA-LLELUJAH!"],
        "passive-aggressive": ["No, no. I LOVE the seventh verse.", "Some of us are in tune. Just saying.", "Lovely. Really. Keep going."],
        "good_colleague": ["Tidlig mandags morgen!", "Så gjør vi så når vi vasker vårt tøy", "En gang til!"],
    ]

    static let CAROL_GENERIC_ASIDES = [
        "Left hoof, right hoof.",
        "I'm getting dizzy.",
        "Who's leading? Is anyone leading?",
    ]

    static let CAROL_FINALE_LINES = [
        "God jul!",
        "And that's the tree, circled.",
        "Same time next year.",
    ]

    static let GIFT_QUIPS = [
        "Socks! ...made of wool. Awkward.",
        "A scarf. From whose wool?!",
        "It's a tiny bell!",
        "A marzipan pig. Nice.",
    ]

    static let GIFT_PERSONALITY_QUIPS: [String: [String]] = [
        "snarky": ["Wool socks. Is this a threat?", "Regifted. I can tell.", "Oh good. Another candle."],
        "wholesome": ["I love it! What is it?", "You remembered!", "Best present ever!"],
        "chaotic": ["IT'S A BOX! I LOVE BOX!", "I ATE THE WRAPPING!", "MINE MINE MINE"],
        "passive-aggressive": ["Oh. You shouldn't have. Really.", "It's... certainly a gift.", "I'll treasure it. Somewhere."],
        "good_colleague": ["Marsipangris! Takk!", "Nok et slips. Flott.", "Kaffekopp. Akkurat det jeg ønsket meg."],
    ]

    static let GIFT_FINALE_LINES = [
        "God jul, everyone!",
        "Best. Julaften. Ever.",
        "Same presents next year, then.",
    ]
}

/// Poke a sheep's state machine directly (TS: `(sheep as any).state = …;
/// stateTimer = 0; stateDuration = …`).
private func poke(_ sheep: Sheep, _ state: SheepState, _ duration: Double) {
    sheep.state = state
    sheep.stateTimer = 0
    sheep.stateDuration = duration
}

/// Poke, unless the participant is grabbed, airborne, petted or chatting —
/// it's left alone and rejoins once it's free again.
private func direct(_ sheep: Sheep, _ state: SheepState, _ duration: Double) {
    guard sheep.canBeDirected else { return }
    poke(sheep, state, duration)
}

/// Check if enough sheep are calm and near each other to start a group activity
func canStartGroupActivity(_ sheepList: [(id: String, x: Double, calm: Bool)]) -> [String]? {
    // Need at least 3 calm sheep within 5 display widths of each other
    let calm = sheepList.filter { $0.calm }
    if calm.count < 3 { return nil }

    // Find a cluster — check if any 3+ are within range
    for i in 0..<calm.count {
        var cluster = [calm[i]]
        for j in 0..<calm.count {
            if i == j { continue }
            if abs(calm[i].x - calm[j].x) < GroupActivityData.DISPLAY_SIZE * 5 {
                cluster.append(calm[j])
            }
        }
        if cluster.count >= 3 {
            return cluster.map { $0.id }
        }
    }
    return nil
}

func createGroupActivity(_ type: GroupActivityType, _ participants: [String], _ centerX: Double) -> GroupActivity {
    // The TS builds the whole `durations` record (in this order) before
    // indexing it, so every entry consumes its random roll.
    let campfireCircle = 15000 + SimRandom.next() * 10000
    let followLeader = 10000 + SimRandom.next() * 5000
    let syncBounce: Double = 6000
    let huddle = 10000 + SimRandom.next() * 5000
    let easterEggHunt = 20000 + SimRandom.next() * 10000
    let sunbathe = 14000 + SimRandom.next() * 8000

    let duration: Double
    switch type {
    case .campfireCircle: duration = campfireCircle
    case .followLeader: duration = followLeader
    case .syncBounce: duration = syncBounce
    case .huddle: duration = huddle
    case .easterEggHunt: duration = easterEggHunt
    case .sunbathe: duration = sunbathe
    // Not part of the TS record: rolled only when picked, so the older
    // types keep their random sequence.
    case .juletregang: duration = 20000 + SimRandom.next() * 8000
    case .giftExchange: duration = 22000 + SimRandom.next() * 8000
    }

    let activity = GroupActivity(type: type, participants: participants, phase: .gathering, timer: 0,
                                 duration: duration, centerX: centerX)
    if type == .followLeader {
        activity.leaderId = participants.isEmpty ? nil : participants[SimRandom.int(participants.count)]
    }
    if type == .syncBounce { activity.bounceCount = 0 }
    if type == .easterEggHunt {
        activity.eggAssignments = [:]
        activity.collectedEggs = []
        activity.eggReactionTimer = 0
        activity.eggFinders = [:]
    }
    if type == .sunbathe { activity.quipTimer = 3000 }
    if type == .juletregang {
        activity.carolTimer = 600
        activity.noteTimer = 300
        activity.carolCount = 0
    }
    if type == .giftExchange {
        activity.giftAssignments = [:]
        activity.giftsOpened = 0
    }
    return activity
}

func pickActivityType(_ easterTheme: EasterTheme? = nil, _ summerTheme: SummerTheme? = nil,
                      _ christmasTheme: ChristmasTheme? = nil) -> GroupActivityType {
    if let easterTheme, easterTheme.active, SimRandom.next() < 0.4 {
        return .easterEggHunt
    }
    if let summerTheme, summerTheme.active, SimRandom.next() < 0.4 {
        return .sunbathe
    }
    if let christmasTheme, christmasTheme.active, SimRandom.next() < 0.5 {
        return SimRandom.next() < 0.5 ? .juletregang : .giftExchange
    }
    let types: [GroupActivityType] = [.campfireCircle, .followLeader, .syncBounce, .huddle]
    return types[SimRandom.int(types.count)]
}

/// Returns true while activity is still running, false when done
func updateGroupActivity(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                         _ easterTheme: EasterTheme? = nil, _ christmasTheme: ChristmasTheme? = nil) -> Bool {
    activity.timer += dt

    switch activity.phase {
    case .gathering:
        return updateGathering(activity, dt, getSheep, easterTheme, christmasTheme)
    case .performing:
        return updatePerforming(activity, dt, getSheep, easterTheme, christmasTheme)
    case .celebrating:
        return updateCelebrating(activity, dt, getSheep, easterTheme)
    case .dispersing:
        return updateDispersing(activity)
    }
}

private func updateGathering(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                             _ easterTheme: EasterTheme?, _ christmasTheme: ChristmasTheme?) -> Bool {
    let DISPLAY_SIZE = GroupActivityData.DISPLAY_SIZE
    var allGathered = true

    for id in activity.participants {
        guard let entry = getSheep(id) else { continue }
        let sheep = entry.sheep

        // Set walk target toward center
        if sheep.walkTarget == nil && abs(sheep.x - activity.centerX) > DISPLAY_SIZE * 1.5 {
            let index = activity.participants.firstIndex(of: id) ?? -1
            sheep.walkTarget = activity.centerX + Double(index - 1) * DISPLAY_SIZE * 0.8
        }

        if abs(sheep.x - activity.centerX) > DISPLAY_SIZE * 2 {
            allGathered = false
        }
    }

    // Timeout gathering after 8s — just start performing. The tree can be
    // most of a screen away, so the Christmas activities wait longer.
    let timeout = activity.type.gathersAtTree ? GroupActivityData.TREE_GATHER_TIMEOUT_MS : 8000
    if allGathered || activity.timer > timeout {
        activity.phase = .performing
        activity.timer = 0

        if activity.type == .giftExchange {
            christmasTheme?.resetPresents()
        }

        if activity.type == .easterEggHunt, let easterTheme {
            easterTheme.prepareHunt(activity.participants)
            activity.huntSummary = EasterHuntSummary(
                totalEggs: easterTheme.getEggPositions().count,
                durationMs: 0,
                allCollected: false,
                paintedEggsUsed: easterTheme.getPaintedEggsUsedCount(),
                winnerId: nil,
                finders: []
            )
        }

        // Announce the activity
        let first = activity.participants.first.flatMap { getSheep($0) }
        if activity.type == .huddle {
            first?.bubble.show("Group meeting!", duration: 3000)
        } else if activity.type == .campfireCircle {
            first?.bubble.show("Campfire time!", duration: 3000)
        } else if activity.type == .easterEggHunt {
            first?.bubble.show("Easter egg hunt!", duration: 3000)
        } else if activity.type == .sunbathe {
            first?.bubble.show("Sunbathing time!", duration: 3000)
        } else if activity.type == .juletregang {
            first?.bubble.show("Everyone around the tree!", duration: 3000)
        } else if activity.type == .giftExchange {
            first?.bubble.show("Presents!", duration: 3000)
        }
    }

    return true
}

private func updatePerforming(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                              _ easterTheme: EasterTheme?, _ christmasTheme: ChristmasTheme?) -> Bool {
    switch activity.type {
    case .campfireCircle:
        // First participant does campfire, others sit nearby
        for i in 0..<activity.participants.count {
            guard let entry = getSheep(activity.participants[i]) else { continue }
            let sheep = entry.sheep
            if i == 0 && sheep.state != .idleCampfire && sheep.canBeDirected {
                sheep.playAnimation(.bounce) // will transition to campfire via bored state
                // Directly set state for leader
                poke(sheep, .idleCampfire, activity.duration)
                sheep.campfireSparks = []
            } else if i > 0 && sheep.state != .sit {
                direct(sheep, .sit, activity.duration)
            }
        }

    case .followLeader:
        // Leader walks, others follow
        if let leader = activity.leaderId.flatMap({ getSheep($0) }) {
            if leader.sheep.state != .walk && leader.sheep.canBeDirected {
                leader.sheep.facingRight = SimRandom.next() > 0.5
                direct(leader.sheep, .walk, activity.duration)
            }
            // Others follow leader
            for id in activity.participants {
                if id == activity.leaderId { continue }
                if let follower = getSheep(id) {
                    follower.sheep.walkTarget = leader.sheep.x
                }
            }
        }

    case .syncBounce:
        // Synchronized bouncing every 1.5s
        let interval: Double = 1500
        let expectedBounces = Int((activity.timer / interval).rounded(.down))
        if let bounceCount = activity.bounceCount, expectedBounces > bounceCount, bounceCount < 4 {
            activity.bounceCount = expectedBounces
            for i in 0..<activity.participants.count {
                if let entry = getSheep(activity.participants[i]) {
                    // Stagger slightly for cascade effect
                    SimTimers.after(Double(i) * 150) { entry.sheep.playAnimation(.bounce) }
                }
            }
        }

    case .huddle:
        // Everyone sits close together
        for id in activity.participants {
            guard let entry = getSheep(id) else { continue }
            if entry.sheep.state != .sit && entry.sheep.state != .idle {
                direct(entry.sheep, .sit, activity.duration)
            }
        }

    case .easterEggHunt:
        let finished = updateEasterEggHunt(activity, dt, getSheep, easterTheme)
        if finished {
            startHuntCelebration(activity, getSheep, easterTheme)
            return true
        }

    case .sunbathe:
        // Everyone flops down and soaks up the sun
        for id in activity.participants {
            guard let entry = getSheep(id) else { continue }
            if entry.sheep.state != .sit {
                direct(entry.sheep, .sit, activity.duration)
            }
        }

        // A lazy quip every few seconds from a random sunbather
        if var quipTimer = activity.quipTimer {
            quipTimer -= dt
            activity.quipTimer = quipTimer
            if quipTimer <= 0 {
                activity.quipTimer = 4500 + SimRandom.next() * 4000
                let id = activity.participants.isEmpty
                    ? nil : activity.participants[SimRandom.int(activity.participants.count)]
                if let id, let entry = getSheep(id), !entry.bubble.visible {
                    entry.bubble.show(SUNBATHE_QUIPS[SimRandom.int(SUNBATHE_QUIPS.count)], duration: 3000)
                }
            }
        }

    case .juletregang:
        updateJuletregang(activity, dt, getSheep, christmasTheme)

    case .giftExchange:
        if updateGiftExchange(activity, dt, getSheep, christmasTheme) {
            finishWithCheer(activity, getSheep, GroupActivityData.GIFT_FINALE_LINES)
            return true
        }
    }

    if activity.timer >= activity.duration {
        if activity.type == .easterEggHunt {
            finalizeHuntSummary(activity, easterTheme, false)
            easterTheme?.finishHunt()
        }
        if activity.type == .juletregang {
            finishWithCheer(activity, getSheep, GroupActivityData.CAROL_FINALE_LINES)
        } else {
            startDispersing(activity, getSheep)
        }
    }

    return true
}

/// The key the personality-flavoured line pools use: Good Colleague has his
/// own pool even though he also has a regular personality.
private func linePoolKey(_ id: String, _ entry: FlockCharacter) -> String {
    id == "good_colleague" ? "good_colleague" : (entry.personality ?? "")
}

/// Everyone hops, one sheep gets the last word, then the flock wanders off.
private func finishWithCheer(_ activity: GroupActivity, _ getSheep: GroupActivityLookup, _ lines: [String]) {
    for id in activity.participants {
        if let entry = getSheep(id) { entry.sheep.playAnimation(.bounce) }
    }
    if let speaker = activity.participants.first.flatMap({ getSheep($0) }) {
        speaker.bubble.show(lines[SimRandom.int(lines.count)], duration: 3000)
    }
    startDispersing(activity, getSheep)
}

/// Gang rundt juletreet. Seen from the side, a ring around the tree is a
/// file of sheep walking back and forth past it, half of them each way.
private func updateJuletregang(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                               _ christmasTheme: ChristmasTheme?) {
    let radius = GroupActivityData.TREE_RING_RADIUS
    var singers: [FlockCharacter] = []

    for (index, id) in activity.participants.enumerated() {
        guard let entry = getSheep(id) else { continue }
        let sheep = entry.sheep
        guard sheep.canBeDirected else { continue }
        sheep.walkTarget = nil

        let offset = sheep.x - activity.centerX
        if offset > radius {
            sheep.facingRight = false
        } else if offset < -radius {
            sheep.facingRight = true
        } else if sheep.state != .walk {
            // Joining (or back from a hop): every other sheep goes the other way round
            sheep.facingRight = index % 2 == 0
        }
        if sheep.state != .walk {
            poke(sheep, .walk, activity.duration)
        }
        if abs(offset) <= radius * 1.5 { singers.append(entry) }
    }
    if singers.isEmpty { return }

    // A note drifts up from whoever is singing
    if var noteTimer = activity.noteTimer {
        noteTimer -= dt
        if noteTimer <= 0 {
            noteTimer = 450 + SimRandom.next() * 350
            let sheep = singers[SimRandom.int(singers.count)].sheep
            let headX = sheep.x + sheep.displaySize * (sheep.facingRight ? 0.8 : 0.2)
            christmasTheme?.emitNote(headX, sheep.y + sheep.displaySize * 0.15)
        }
        activity.noteTimer = noteTimer
    }

    // Verses and mutterings take turns
    if var carolTimer = activity.carolTimer {
        carolTimer -= dt
        if carolTimer <= 0 {
            carolTimer = 4200 + SimRandom.next() * 1200
            let count = activity.carolCount ?? 0
            let id = activity.participants[count % activity.participants.count]
            if let entry = getSheep(id), !entry.bubble.visible {
                let lines = GroupActivityData.CAROL_LINES
                let pool = count % 2 == 0
                    ? [lines[(count / 2) % lines.count]]
                    : GroupActivityData.CAROL_ASIDES[linePoolKey(id, entry)] ?? GroupActivityData.CAROL_GENERIC_ASIDES
                entry.bubble.show(pool[SimRandom.int(pool.count)], duration: 3400)
            }
            activity.carolCount = count + 1
        }
        activity.carolTimer = carolTimer
    }
}

/// One present each: walk to it, open it, react. Returns true once every
/// present that was handed out has been opened.
private func updateGiftExchange(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                                _ christmasTheme: ChristmasTheme?) -> Bool {
    guard let christmasTheme, var assignments = activity.giftAssignments else {
        // No tree, no presents: just sit together until the time is up
        sitTogether(activity, getSheep)
        return false
    }
    let presents = christmasTheme.getPresentPositions()
    if presents.isEmpty {
        sitTogether(activity, getSheep)
        return false
    }

    // Hand out the presents once: nearest one that is still free
    if assignments.isEmpty {
        var free = presents.enumerated().filter { !$0.element.opened }.map { (index: $0.offset, x: $0.element.x) }
        for id in activity.participants {
            guard !free.isEmpty, let entry = getSheep(id) else { continue }
            let center = entry.sheep.x + entry.sheep.displaySize / 2
            var best = 0
            for i in free.indices where abs(free[i].x - center) < abs(free[best].x - center) {
                best = i
            }
            assignments[id] = free.remove(at: best).index
        }
        activity.giftAssignments = assignments
        if assignments.isEmpty { return false }
    }

    var waiting = 0
    for id in activity.participants {
        guard let entry = getSheep(id) else { continue }
        guard let index = assignments[id], presents.indices.contains(index), !presents[index].opened else {
            // Opened theirs (or there was none left): sit and admire it
            if entry.sheep.state != .sit && entry.sheep.state != .idle {
                direct(entry.sheep, .sit, activity.duration)
            }
            continue
        }
        waiting += 1

        let present = presents[index]
        let sheepCenter = entry.sheep.x + entry.sheep.displaySize / 2
        if abs(sheepCenter - present.x) < GroupActivityData.PRESENT_OPEN_RADIUS {
            christmasTheme.openPresent(index)
            activity.giftsOpened = (activity.giftsOpened ?? 0) + 1
            waiting -= 1
            entry.sheep.playAnimation(.bounce)
            let pool = GroupActivityData.GIFT_PERSONALITY_QUIPS[linePoolKey(id, entry)] ?? GroupActivityData.GIFT_QUIPS
            entry.bubble.show(pool[SimRandom.int(pool.count)], duration: 3000)
            continue
        }

        // Steer by facing only, like the egg hunt: walkTarget's arrival
        // radius is far larger than the reach of a present
        entry.sheep.walkTarget = nil
        entry.sheep.facingRight = present.x > sheepCenter
        let state = entry.sheep.state
        if state == .idle || state == .sit || state == .idleSleep || state == .idleCampfire ||
            state == .idleCounting || state == .idleEggPainting {
            direct(entry.sheep, .walk, 15000)
        }
    }

    return waiting == 0
}

private func sitTogether(_ activity: GroupActivity, _ getSheep: GroupActivityLookup) {
    for id in activity.participants {
        guard let entry = getSheep(id) else { continue }
        if entry.sheep.state != .sit && entry.sheep.state != .idle {
            direct(entry.sheep, .sit, activity.duration)
        }
    }
}

private func updateCelebrating(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                               _ easterTheme: EasterTheme?) -> Bool {
    if activity.type != .easterEggHunt {
        startDispersing(activity, getSheep)
        return true
    }

    if let reaction = activity.eggReactionTimer, reaction > 0 {
        activity.eggReactionTimer = reaction - dt
        if reaction - dt <= 0 {
            let summary = finalizeHuntSummary(activity, easterTheme, true)
            if let winnerId = summary?.winnerId {
                if let winner = getSheep(winnerId), !winner.bubble.visible {
                    let lines = GroupActivityData.EGG_HUNT_WINNER_LINES
                    winner.bubble.show(lines[SimRandom.int(lines.count)], duration: 2400)
                }
            }
            activity.eggReactionTimer = 0
        }
    }

    if activity.timer >= 2200 {
        easterTheme?.finishHunt()
        startDispersing(activity, getSheep)
    }
    return true
}

private func updateEasterEggHunt(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                                 _ easterTheme: EasterTheme?) -> Bool {
    guard let easterTheme, var eggAssignments = activity.eggAssignments,
          var collectedEggs = activity.collectedEggs else { return false }

    let eggs = easterTheme.getEggPositions()
    var uncollected: [(index: Int, x: Double)] = []
    for (i, e) in eggs.enumerated() where !e.found && !collectedEggs.contains(i) {
        uncollected.append((i, e.x))
    }

    // Assign unassigned participants to eggs
    for id in activity.participants {
        if let targetIdx = eggAssignments[id] {
            // Check if their target egg was already collected
            if collectedEggs.contains(targetIdx) {
                eggAssignments.removeValue(forKey: id)
            }
        }

        if eggAssignments[id] == nil && !uncollected.isEmpty {
            // Assign nearest uncollected egg
            guard let entry = getSheep(id) else { continue }
            var nearest = uncollected[0]
            var nearestDist = abs(entry.sheep.x - nearest.x)
            for egg in uncollected {
                let dist = abs(entry.sheep.x - egg.x)
                if dist < nearestDist {
                    nearest = egg
                    nearestDist = dist
                }
            }
            eggAssignments[id] = nearest.index
            // Remove from uncollected so others pick different eggs
            if let idx = uncollected.firstIndex(where: { $0.index == nearest.index }) {
                uncollected.remove(at: idx)
            }
        }
    }

    // Move participants toward their eggs and check for collection
    for id in activity.participants {
        guard let entry = getSheep(id) else { continue }

        guard let targetIdx = eggAssignments[id] else {
            // No eggs left to find — sit happily
            if entry.sheep.state != .sit && entry.sheep.state != .idle {
                direct(entry.sheep, .sit, activity.duration)
            }
            continue
        }

        guard targetIdx >= 0, targetIdx < eggs.count else { continue }
        let egg = eggs[targetIdx]

        // Check if reached the egg — compare sheep center to egg center
        let sheepCenter = entry.sheep.x + entry.sheep.displaySize / 2
        if abs(sheepCenter - egg.x) < GroupActivityData.EGG_COLLECTION_RADIUS {
            collectedEggs.insert(targetIdx)
            eggAssignments.removeValue(forKey: id)
            easterTheme.collectEgg(targetIdx, id)
            var finder = activity.eggFinders?[id] ?? EasterHuntFinder(eggsFound: 0, goldenEggsFound: 0)
            finder.eggsFound += 1
            if egg.golden { finder.goldenEggsFound += 1 }
            activity.eggFinders?[id] = finder

            // Show reaction
            entry.sheep.playAnimation(.bounce)
            // Good Colleague gets its dedicated pool even though it also has a
            // regular personality
            let personalityKey = id == "good_colleague" ? "good_colleague" : (entry.personality ?? "")
            let quipPool = GroupActivityData.EGG_HUNT_PERSONALITY_QUIPS[personalityKey]
                ?? GroupActivityData.EGG_HUNT_QUIPS
            let quip = quipPool[SimRandom.int(quipPool.count)]
            entry.bubble.show(quip, duration: 3000)
            continue
        }

        // Steer toward the egg by facing only — walkTarget's arrival radius
        // (1.5×displaySize) is far larger than the collection radius, so the
        // sit-on-arrival logic would thrash walk/sit for the final approach
        entry.sheep.walkTarget = nil
        entry.sheep.facingRight = egg.x > sheepCenter
        let state = entry.sheep.state
        if state == .idle || state == .sit || state == .idleSleep || state == .idleCampfire ||
            state == .idleCounting || state == .idleEggPainting {
            direct(entry.sheep, .walk, 15000) // long enough to reach the egg
        }
    }

    // The TS mutates the activity's Map/Set in place; write our copies back.
    activity.eggAssignments = eggAssignments
    activity.collectedEggs = collectedEggs

    return collectedEggs.count >= eggs.count && !eggs.isEmpty
}

private func updateDispersing(_ activity: GroupActivity) -> Bool {
    // Dispersal lasts 3s then activity ends
    activity.timer < 3000
}

private func startDispersing(_ activity: GroupActivity, _ getSheep: GroupActivityLookup) {
    let DISPLAY_SIZE = GroupActivityData.DISPLAY_SIZE
    activity.phase = .dispersing
    activity.timer = 0

    for id in activity.participants {
        if let entry = getSheep(id) {
            let dir: Double = SimRandom.next() > 0.5 ? 1 : -1
            entry.sheep.walkTarget = entry.sheep.x + dir * (DISPLAY_SIZE * 2 + SimRandom.next() * DISPLAY_SIZE * 3)
        }
    }
}

private func startHuntCelebration(_ activity: GroupActivity, _ getSheep: GroupActivityLookup,
                                  _ easterTheme: EasterTheme?) {
    let summary = finalizeHuntSummary(activity, easterTheme, true)
    activity.phase = .celebrating
    activity.timer = 0
    activity.eggReactionTimer = 850

    let speakerId = summary?.winnerId ?? activity.participants.first
    let speaker = speakerId.flatMap { $0.isEmpty ? nil : getSheep($0) }
    if let speaker {
        let lines = GroupActivityData.EGG_HUNT_VICTORY_LINES
        speaker.bubble.show(lines[SimRandom.int(lines.count)], duration: 2200)
    }

    for id in activity.participants {
        if let entry = getSheep(id) {
            entry.sheep.playAnimation(.bounce)
        }
    }
}

@discardableResult
private func finalizeHuntSummary(_ activity: GroupActivity, _ easterTheme: EasterTheme?,
                                 _ allCollected: Bool = false) -> EasterHuntSummary? {
    if activity.type != .easterEggHunt { return nil }

    var finders: [EasterHuntSummary.Finder] = activity.participants.map { id in
        let stats = activity.eggFinders?[id]
        return EasterHuntSummary.Finder(id: id, eggsFound: stats?.eggsFound ?? 0,
                                        goldenEggsFound: stats?.goldenEggsFound ?? 0)
    }
    // JS `Array.prototype.sort` is stable; Swift's isn't documented to be.
    finders = finders.enumerated().sorted { l, r in
        if l.element.eggsFound != r.element.eggsFound { return l.element.eggsFound > r.element.eggsFound }
        if l.element.goldenEggsFound != r.element.goldenEggsFound {
            return l.element.goldenEggsFound > r.element.goldenEggsFound
        }
        return l.offset < r.offset
    }.map(\.element)

    let winnerId: String? = if let first = finders.first, first.eggsFound > 0 { first.id } else { nil }
    // The summary is seeded with `durationMs: 0` when the hunt starts, so 0
    // means "not captured yet": the first finalize (hunt end, still in
    // performing) captures the elapsed time, and the celebration's re-finalize
    // — after `activity.timer` was reset — keeps it. (The TS used `??` on the
    // seeded 0, so the duration was never captured.)
    let capturedMs = activity.huntSummary?.durationMs ?? 0
    let summary = EasterHuntSummary(
        totalEggs: activity.huntSummary?.totalEggs ?? easterTheme?.getEggPositions().count
            ?? activity.collectedEggs?.count ?? 0,
        durationMs: capturedMs > 0 ? capturedMs : activity.timer,
        allCollected: allCollected,
        paintedEggsUsed: activity.huntSummary?.paintedEggsUsed ?? easterTheme?.getPaintedEggsUsedCount() ?? 0,
        winnerId: winnerId,
        finders: finders
    )
    activity.huntSummary = summary
    return summary
}
