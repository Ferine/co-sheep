import Foundation

// Ex-group-activities.ts: rare flock-wide activities (campfire circle, follow
// the leader, sync bounce, huddle, Easter egg hunt, sunbathe). Pure sim: the
// activities steer sheep by poking their state machine (the TS does the same
// through `as any`) and draw nothing themselves — the Easter eggs come from
// `EasterTheme`, everything else is the sheep's own draw code.

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
}

/// Poke a sheep's state machine directly (TS: `(sheep as any).state = …;
/// stateTimer = 0; stateDuration = …`).
private func poke(_ sheep: Sheep, _ state: SheepState, _ duration: Double) {
    sheep.state = state
    sheep.stateTimer = 0
    sheep.stateDuration = duration
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
    return activity
}

func pickActivityType(_ easterTheme: EasterTheme? = nil, _ summerTheme: SummerTheme? = nil) -> GroupActivityType {
    if let easterTheme, easterTheme.active, SimRandom.next() < 0.4 {
        return .easterEggHunt
    }
    if let summerTheme, summerTheme.active, SimRandom.next() < 0.4 {
        return .sunbathe
    }
    let types: [GroupActivityType] = [.campfireCircle, .followLeader, .syncBounce, .huddle]
    return types[SimRandom.int(types.count)]
}

/// Returns true while activity is still running, false when done
func updateGroupActivity(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                         _ easterTheme: EasterTheme? = nil) -> Bool {
    activity.timer += dt

    switch activity.phase {
    case .gathering:
        return updateGathering(activity, dt, getSheep, easterTheme)
    case .performing:
        return updatePerforming(activity, dt, getSheep, easterTheme)
    case .celebrating:
        return updateCelebrating(activity, dt, getSheep, easterTheme)
    case .dispersing:
        return updateDispersing(activity)
    }
}

private func updateGathering(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                             _ easterTheme: EasterTheme?) -> Bool {
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

    // Timeout gathering after 8s — just start performing
    if allGathered || activity.timer > 8000 {
        activity.phase = .performing
        activity.timer = 0

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
        }
    }

    return true
}

private func updatePerforming(_ activity: GroupActivity, _ dt: Double, _ getSheep: GroupActivityLookup,
                              _ easterTheme: EasterTheme?) -> Bool {
    switch activity.type {
    case .campfireCircle:
        // First participant does campfire, others sit nearby
        for i in 0..<activity.participants.count {
            guard let entry = getSheep(activity.participants[i]) else { continue }
            let sheep = entry.sheep
            if i == 0 && sheep.state != .idleCampfire {
                sheep.playAnimation(.bounce) // will transition to campfire via bored state
                // Directly set state for leader
                poke(sheep, .idleCampfire, activity.duration)
                sheep.campfireSparks = []
            } else if i > 0 && sheep.state != .sit {
                poke(sheep, .sit, activity.duration)
            }
        }

    case .followLeader:
        // Leader walks, others follow
        if let leader = activity.leaderId.flatMap({ getSheep($0) }) {
            if leader.sheep.state != .walk {
                leader.sheep.facingRight = SimRandom.next() > 0.5
                poke(leader.sheep, .walk, activity.duration)
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
                poke(entry.sheep, .sit, activity.duration)
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
                poke(entry.sheep, .sit, activity.duration)
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
    }

    if activity.timer >= activity.duration {
        if activity.type == .easterEggHunt {
            finalizeHuntSummary(activity, easterTheme, false)
            easterTheme?.finishHunt()
        }
        startDispersing(activity, getSheep)
    }

    return true
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
                poke(entry.sheep, .sit, activity.duration)
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
            poke(entry.sheep, .walk, 15000) // long enough to reach the egg
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
    let summary = EasterHuntSummary(
        totalEggs: activity.huntSummary?.totalEggs ?? easterTheme?.getEggPositions().count
            ?? activity.collectedEggs?.count ?? 0,
        // Keep the duration captured at hunt end — the celebration phase
        // re-finalizes after resetting activity.timer
        durationMs: activity.huntSummary?.durationMs ?? activity.timer,
        allCollected: allCollected,
        paintedEggsUsed: activity.huntSummary?.paintedEggsUsed ?? easterTheme?.getPaintedEggsUsedCount() ?? 0,
        winnerId: winnerId,
        finders: finders
    )
    activity.huntSummary = summary
    return summary
}
