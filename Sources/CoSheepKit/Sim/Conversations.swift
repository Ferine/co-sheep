import Foundation

// Ex-conversations.ts.

private typealias ScriptTemplate = ConversationScript

struct ConversationContext {
    var personalityA: FriendPersonality?
    var personalityB: FriendPersonality?
    var weather: String?
    var hour: Int?
    var easterTheme: (any EasterThemeHooks)?
    var recentEasterHunt: Bool
    var eggPaintingActive: Bool
    var summerActive: Bool

    init(personalityA: FriendPersonality? = nil,
         personalityB: FriendPersonality? = nil,
         weather: String? = nil,
         hour: Int? = nil,
         easterTheme: (any EasterThemeHooks)? = nil,
         recentEasterHunt: Bool = false,
         eggPaintingActive: Bool = false,
         summerActive: Bool = false) {
        self.personalityA = personalityA
        self.personalityB = personalityB
        self.weather = weather
        self.hour = hour
        self.easterTheme = easterTheme
        self.recentEasterHunt = recentEasterHunt
        self.eggPaintingActive = eggPaintingActive
        self.summerActive = summerActive
    }
}

private func scriptLine(_ speakerId: String, _ text: String, _ duration: Double, _ delay: Double,
                  _ animation: SheepAnimation? = nil) -> ConversationLine {
    ConversationLine(speakerId: speakerId, text: text, duration: duration, delay: delay, animation: animation)
}

// $A and $B are placeholders resolved at pick time
private let GENERIC_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Baaaa?", 3000, 0),
        scriptLine("$B", "Baaaa.", 3000, 500),
        scriptLine("$A", "...fair enough.", 3000, 800, .headshake),
    ],
    [
        scriptLine("$A", "*stares*", 2500, 0),
        scriptLine("$B", "*stares back*", 2500, 600),
        scriptLine("$A", "...nice weather.", 3000, 1000),
    ],
    [
        scriptLine("$A", "You ever wonder what's outside the screen?", 4000, 0),
        scriptLine("$B", "Don't be weird.", 3000, 800, .headshake),
    ],
    [
        scriptLine("$A", "What does the human DO all day?", 4000, 0),
        scriptLine("$B", "I try not to think about it.", 3500, 700),
    ],
    [
        scriptLine("$A", "*yawns*", 2500, 0),
        scriptLine("$B", "*yawns*", 2500, 400),
        scriptLine("$A", "Hey! Stop that!", 3000, 600, .bounce),
    ],
    [
        scriptLine("$B", "You come here often?", 3500, 0),
        scriptLine("$A", "We literally live on the same screen.", 4000, 700, .headshake),
    ],
    [
        scriptLine("$A", "Still thinking about tabs?", 3500, 0),
        scriptLine("$B", "Always.", 2500, 600),
        scriptLine("$A", "Same.", 2000, 500, .headshake),
    ],
    [
        scriptLine("$A", "Do you think pixels dream?", 4000, 0),
        scriptLine("$B", "Only of higher resolution.", 3500, 800),
        scriptLine("$A", "That's deep.", 2500, 600, .bounce),
    ],
    [
        scriptLine("$B", "What's your favorite color?", 3000, 0),
        scriptLine("$A", "I'm literally tinted. Take a guess.", 4000, 700, .headshake),
    ],
    [
        scriptLine("$A", "We should start a band.", 3500, 0),
        scriptLine("$B", "We don't have hands.", 3000, 700),
        scriptLine("$A", "Details.", 2000, 500, .bounce),
    ],
    [
        scriptLine("$A", "Race you to the other side!", 3500, 0),
        scriptLine("$B", "We walk at the same speed.", 3500, 700),
        scriptLine("$A", "So it's fair!", 2500, 600, .zoom),
        scriptLine("$B", "That's not—", 2000, 400),
    ],
    [
        scriptLine("$B", "What if we just... didn't move?", 3500, 0),
        scriptLine("$A", "Revolutionary.", 2500, 700),
        scriptLine("$B", "Thank you. I've been thinking.", 3500, 600),
    ],
]

private let GOOD_COLLEAGUE_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("good_colleague", "Hva skjer?", 3000, 0),
        scriptLine("$OTHER", "...what?", 2500, 600),
        scriptLine("good_colleague", "Nei, ingenting.", 3000, 800, .headshake),
    ],
    [
        scriptLine("good_colleague", "Noen som vil ha kaffe?", 3500, 0),
        scriptLine("$OTHER", "I don't speak... whatever that is.", 4000, 700),
        scriptLine("good_colleague", "*shrugs*", 2500, 600, .headshake),
    ],
    [
        scriptLine("good_colleague", "Viktig meeting klokka tre.", 3500, 0),
        scriptLine("$OTHER", "Are you... scheduling something?", 4000, 800),
        scriptLine("good_colleague", "Bare prat.", 2500, 600),
    ],
    [
        scriptLine("good_colleague", "Kontorlivet er hardt.", 3500, 0),
        scriptLine("$OTHER", "*nods politely*", 2500, 700),
    ],
    [
        scriptLine("good_colleague", "Har du sett TPS-rapporten?", 3500, 0),
        scriptLine("$OTHER", "The... what now?", 3000, 700),
        scriptLine("good_colleague", "Gløm det.", 2500, 600, .headshake),
    ],
    [
        scriptLine("good_colleague", "Lunsjpause snart.", 3000, 0),
        scriptLine("$OTHER", "*stomach growls*", 2500, 600),
        scriptLine("good_colleague", "*tilbyr kaffe*", 3000, 700, .bounce),
    ],
]

private let MAIN_SHEEP_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$FRIEND", "Is it always this judgmental?", 4000, 0),
        scriptLine("main", "I prefer 'observant'.", 3500, 700, .headshake),
    ],
    [
        scriptLine("$FRIEND", "Why does it keep looking at the screen?", 4500, 0),
        scriptLine("main", "Wouldn't YOU?", 3000, 800, .bounce),
    ],
    [
        scriptLine("$FRIEND", "What are you thinking about?", 3500, 0),
        scriptLine("main", "How many tabs the human has open. It haunts me.", 5000, 800, .vibrate),
    ],
    [
        scriptLine("$FRIEND", "You seem stressed.", 3000, 0),
        scriptLine("main", "YOU try watching someone code in production.", 4500, 700, .vibrate),
    ],
    [
        scriptLine("$FRIEND", "Do you ever take a break?", 3500, 0),
        scriptLine("main", "I literally told the human that 5 minutes ago.", 4500, 700, .headshake),
        scriptLine("$FRIEND", "Did they listen?", 3000, 600),
        scriptLine("main", "What do you think.", 3000, 700),
    ],
]

// --- Summer scripts (active during warm clear summer weather) ---

private let SUMMER_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Is it just me or is the sun EXTRA today?", 4000, 0),
        scriptLine("$B", "It's not just you. My wool is cooking.", 4000, 700, .vibrate),
    ],
    [
        scriptLine("$A", "We should get ice cream.", 3000, 0),
        scriptLine("$B", "We're pixels. On a screen.", 3500, 700),
        scriptLine("$A", "...pixel ice cream then.", 3000, 800, .bounce),
    ],
    [
        scriptLine("$A", "A butterfly just followed me for ten minutes.", 4000, 0),
        scriptLine("$B", "It thinks you're a flower. Bold of it.", 4000, 800, .headshake),
    ],
    [
        scriptLine("$A", "Summer plans?", 2500, 0),
        scriptLine("$B", "Standing here. Slightly to the left maybe.", 4000, 700),
        scriptLine("$A", "Ambitious.", 2500, 700),
    ],
    [
        scriptLine("$A", "The human is inside on a day like THIS?", 4000, 0),
        scriptLine("$B", "Shh. If they leave, who do we judge?", 4000, 800),
    ],
]

private let SUMMER_GC_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("good_colleague", "Fellesferie snart.", 3000, 0),
        scriptLine("$OTHER", "You say that every day.", 3500, 700),
        scriptLine("good_colleague", "*ser drøymande ut*", 3000, 700),
    ],
    [
        scriptLine("$OTHER", "Aren't you hot in that tie?", 3500, 0),
        scriptLine("good_colleague", "Det er sommartider. Kortermet skjorte.", 3500, 800),
        scriptLine("$OTHER", "...you look exactly the same.", 3500, 700, .headshake),
    ],
    [
        scriptLine("good_colleague", "Fin dag. Kaffi ute?", 3000, 0),
        scriptLine("$OTHER", "Hot coffee? In this heat?", 3000, 700),
        scriptLine("good_colleague", "Ja.", 2000, 600),
    ],
]

// Only valid when Good Colleague himself is a participant — the script
// names him as a speaker, so it can't live in the generic main pool
private let MAIN_GC_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("good_colleague", "Bra jobba i dag.", 3000, 0),
        scriptLine("main", "He just complimented you... I think.", 4500, 700),
    ],
]

// --- Personality-pair scripts ---

private let SNARKY_WHOLESOME_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Everything is terrible.", 3500, 0),
        scriptLine("$B", "But at least we have each other!", 3500, 700, .bounce),
        scriptLine("$A", "That's... not the comfort you think it is.", 4000, 800, .headshake),
    ],
    [
        scriptLine("$B", "I made you a friendship pixel!", 3500, 0, .bounce),
        scriptLine("$A", "It's a white dot.", 2500, 700),
        scriptLine("$B", "A friendship white dot!", 3000, 600),
        scriptLine("$A", "...", 2000, 500, .headshake),
    ],
    [
        scriptLine("$A", "Stop being so positive. It's suspicious.", 4000, 0),
        scriptLine("$B", "I can't help it! Life is wonderful!", 4000, 800, .bounce),
        scriptLine("$A", "*visible discomfort*", 2500, 600),
    ],
]

private let CHAOTIC_CHAOTIC_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "WHAT IF WE SPIN AT THE SAME TIME", 3500, 0, .spin),
        scriptLine("$B", "GENIUS", 2000, 500, .spin),
        scriptLine("$A", "I'M SO DIZZY", 2500, 600),
        scriptLine("$B", "AGAIN???", 2000, 400, .bounce),
    ],
    [
        scriptLine("$A", "I just had the BEST idea", 3500, 0, .bounce),
        scriptLine("$B", "TELL ME TELL ME", 2500, 500),
        scriptLine("$A", "I forgot it.", 2500, 600),
        scriptLine("$B", "THAT WAS THE BEST IDEA", 3500, 500, .zoom),
    ],
]

private let PA_SNARKY_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "I'm FINE.", 2500, 0),
        scriptLine("$B", "Nobody asked.", 2500, 700, .headshake),
        scriptLine("$A", "Wow. Okay then.", 3000, 600),
    ],
    [
        scriptLine("$A", "Must be nice having opinions.", 3500, 0),
        scriptLine("$B", "It is, actually.", 3000, 700),
        scriptLine("$A", "I wouldn't know. I'm just standing here. Alone.", 4500, 800),
    ],
]

private let WHOLESOME_WHOLESOME_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "You're my best friend!", 3000, 0, .bounce),
        scriptLine("$B", "No, YOU'RE my best friend!", 3000, 600, .bounce),
        scriptLine("$A", "This is the best day ever!", 3000, 500, .bounce),
    ],
    [
        scriptLine("$A", "I hope you're having a good day.", 3500, 0),
        scriptLine("$B", "It's better now!", 3000, 700, .bounce),
    ],
]

// --- Time-aware scripts ---

private let MORNING_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Good morning!", 3000, 0, .bounce),
        scriptLine("$B", "*yawns* Is it morning already?", 3500, 700),
    ],
    [
        scriptLine("$A", "Fresh start energy!", 3000, 0, .bounce),
        scriptLine("$B", "I need coffee. I mean grass.", 3500, 700),
    ],
]

private let LATE_NIGHT_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Why are we still awake?", 3500, 0),
        scriptLine("$B", "Because the human is still awake.", 3500, 700),
        scriptLine("$A", "That's concerning.", 3000, 600, .headshake),
    ],
    [
        scriptLine("$A", "*can barely keep eyes open*", 3000, 0),
        scriptLine("$B", "Shhh. Just... rest.", 3000, 700),
    ],
]

private let AFTERNOON_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Post-lunch slump hitting hard.", 3500, 0),
        scriptLine("$B", "Tell me about it.", 2500, 700),
        scriptLine("$A", "*slowly slides down*", 3000, 600),
    ],
]

// --- Weather-aware scripts ---

private let RAIN_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Is that... rain?", 3000, 0),
        scriptLine("$B", "MY WOOL! IT'LL SHRINK!", 3500, 700, .vibrate),
        scriptLine("$A", "We're inside a screen.", 3000, 600, .headshake),
    ],
    [
        scriptLine("$A", "Rainy day. Perfect for napping.", 3500, 0),
        scriptLine("$B", "Couldn't agree more.", 3000, 700),
    ],
]

private let SNOW_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "SNOW!", 2000, 0, .bounce),
        scriptLine("$B", "SNOWBALL FIGHT!", 2500, 500, .bounce),
        scriptLine("$A", "We don't have hands!", 3000, 600, .headshake),
        scriptLine("$B", "HEADBUTT FIGHT!", 2500, 500, .zoom),
    ],
]

private let NICE_WEATHER_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Beautiful day outside.", 3000, 0),
        scriptLine("$B", "And here we are. On a screen.", 3500, 700),
        scriptLine("$A", "Living the dream.", 3000, 600, .headshake),
    ],
]

// --- Easter ---

private let EASTER_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "I found more eggs than you.", 3500, 0),
        scriptLine("$B", "It's not a competition.", 3000, 700),
        scriptLine("$A", "That's what losers say.", 3000, 600, .bounce),
    ],
    [
        scriptLine("$A", "Do you think the eggs were always here?", 4000, 0),
        scriptLine("$B", "What do you mean?", 2500, 800),
        scriptLine("$A", "Like... who hides them? We're sheep.", 4000, 700, .headshake),
    ],
    [
        scriptLine("$A", "I'm going to eat all the chocolate eggs.", 4000, 0, .bounce),
        scriptLine("$B", "Those are painted. Not chocolate.", 3500, 700),
        scriptLine("$A", "...what.", 2000, 600, .vibrate),
    ],
    [
        scriptLine("$A", "Happy Easter!", 2500, 0, .bounce),
        scriptLine("$B", "Baaaa-ster.", 3000, 600, .spin),
        scriptLine("$A", "Please stop.", 2500, 700, .headshake),
    ],
    [
        scriptLine("$A", "Why does Easter move every year?", 3500, 0),
        scriptLine("$B", "Something about the moon.", 3000, 800),
        scriptLine("$A", "The moon controls us all.", 3500, 600, .vibrate),
    ],
    [
        scriptLine("$A", "I've been painting eggs all day.", 3500, 0),
        scriptLine("$B", "They're beautiful.", 2500, 700, .bounce),
        scriptLine("$A", "Thanks. I can't feel my hooves.", 3500, 600),
    ],
    [
        scriptLine("$A", "Do we get Easter off?", 3000, 0),
        scriptLine("$B", "Off from what? We stand on a desktop.", 4000, 700),
        scriptLine("$A", "Fair point.", 2000, 600, .headshake),
    ],
    [
        scriptLine("$A", "Spring is here! I can feel it!", 3500, 0, .bounce),
        scriptLine("$B", "You can feel the changing of seasons?", 3500, 700),
        scriptLine("$A", "No, I just read the calendar.", 3000, 600),
    ],
]

private let EASTER_GC_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("good_colleague", "Påskeegg er seriøs business.", 3500, 0),
        scriptLine("$OTHER", "What?", 2000, 800),
        scriptLine("good_colleague", "Nå er det påske, ja.", 3000, 600, .headshake),
    ],
    [
        scriptLine("good_colleague", "Kvikk Lunsj og påskekrim.", 3500, 0),
        scriptLine("$OTHER", "Is that... a Norwegian Easter thing?", 3500, 800),
        scriptLine("good_colleague", "Det er tradisjon.", 3000, 600, .bounce),
    ],
    [
        scriptLine("good_colleague", "God påske.", 2500, 0, .bounce),
        scriptLine("$OTHER", "Happy Easter to you too!", 3000, 700, .bounce),
    ],
]

private let EASTER_HUNT_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "I still can't believe you missed the golden egg.", 4200, 0),
        scriptLine("$B", "I was busy carrying the team.", 3400, 700, .headshake),
    ],
    [
        scriptLine("$A", "My basket is still full.", 3200, 0),
        scriptLine("$B", "That explains the smugness.", 3400, 700),
    ],
    [
        scriptLine("$A", "Do we get medals for that hunt?", 3200, 0),
        scriptLine("$B", "No. We get more eggs.", 3000, 700, .bounce),
    ],
]

private let EASTER_PAINTING_SCRIPTS: [ScriptTemplate] = [
    [
        scriptLine("$A", "Hold still. This stripe needs emotional support.", 4200, 0),
        scriptLine("$B", "You're talking to the egg again.", 3200, 700, .headshake),
    ],
    [
        scriptLine("$A", "I have paint on my hooves.", 3200, 0),
        scriptLine("$B", "That means it's working.", 2800, 700, .bounce),
    ],
]


// --- Resolver ---

private func resolveScript(_ template: ScriptTemplate, _ idA: String, _ idB: String) -> ConversationScript {
    template.map { l in
        var out = l
        var speakerId = l.speakerId
        if speakerId == "$A" { speakerId = idA }
        else if speakerId == "$B" { speakerId = idB }
        else if speakerId == "$OTHER" { speakerId = idA == "good_colleague" ? idB : idA }
        else if speakerId == "$FRIEND" { speakerId = idA == "main" ? idB : idA }
        out.speakerId = speakerId
        return out
    }
}

private func pickFrom(_ pool: [ScriptTemplate], _ idA: String, _ idB: String) -> ConversationScript? {
    if pool.isEmpty { return nil }
    let template = pool[SimRandom.int(pool.count)]
    return resolveScript(template, idA, idB)
}

private func getPersonalityPairPool(_ pA: FriendPersonality, _ pB: FriendPersonality) -> [ScriptTemplate]? {
    // `[pA, pB].sort().join("+")` — default JS sort is by UTF-16 code units.
    let key = [pA.rawValue, pB.rawValue].sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.joined(separator: "+")
    switch key {
    case "snarky+wholesome": return SNARKY_WHOLESOME_SCRIPTS
    case "chaotic+chaotic": return CHAOTIC_CHAOTIC_SCRIPTS
    case "passive-aggressive+snarky": return PA_SNARKY_SCRIPTS
    case "wholesome+wholesome": return WHOLESOME_WHOLESOME_SCRIPTS
    default: return nil
    }
}

func pickConversation(_ idA: String, _ idB: String, _ context: ConversationContext? = nil) -> ConversationScript? {
    // 50% chance to skip — keeps conversations sparse
    if SimRandom.next() < 0.5 { return nil }

    let hasGC = idA == "good_colleague" || idB == "good_colleague"
    let hasMain = idA == "main" || idB == "main"
    let hour = context?.hour ?? SimClock.hour()

    // Try personality-pair scripts first (30% chance when available)
    if let pA = context?.personalityA, let pB = context?.personalityB, !hasGC, !hasMain {
        if let pairPool = getPersonalityPairPool(pA, pB), SimRandom.next() < 0.4 {
            return pickFrom(pairPool, idA, idB)
        }
    }

    // Try Easter scripts with stronger bias around active seasonal moments.
    if let context, context.easterTheme?.active == true {
        let easterChance = context.recentEasterHunt
            ? 0.8
            : context.eggPaintingActive
                ? 0.65
                : 0.25
        if SimRandom.next() < easterChance {
            if context.recentEasterHunt {
                return pickFrom(EASTER_HUNT_SCRIPTS, idA, idB)
            }
            if context.eggPaintingActive {
                return pickFrom(EASTER_PAINTING_SCRIPTS, idA, idB)
            }
            if hasGC {
                return pickFrom(EASTER_GC_SCRIPTS, idA, idB)
            }
            return pickFrom(EASTER_SCRIPTS, idA, idB)
        }
    }

    // Try summer scripts (seasonal chance during warm clear weather)
    if context?.summerActive == true && SimRandom.next() < 0.25 {
        if hasGC {
            return pickFrom(SUMMER_GC_SCRIPTS, idA, idB)
        }
        return pickFrom(SUMMER_SCRIPTS, idA, idB)
    }

    // Try weather-aware scripts (25% chance when weather active)
    // (`context?.weather &&` is falsy for null, undefined and the empty string)
    if let weather = context?.weather, !weather.isEmpty, SimRandom.next() < 0.25 {
        var weatherPool: [ScriptTemplate] = []
        if weather == "rain" { weatherPool = RAIN_SCRIPTS }
        else if weather == "snow" { weatherPool = SNOW_SCRIPTS }
        else if weather == "clear" { weatherPool = NICE_WEATHER_SCRIPTS }
        if !weatherPool.isEmpty {
            return pickFrom(weatherPool, idA, idB)
        }
    }

    // Try time-aware scripts (20% chance when time matches)
    if SimRandom.next() < 0.2 {
        var timePool: [ScriptTemplate] = []
        if hour >= 6 && hour <= 9 { timePool = MORNING_SCRIPTS }
        else if hour >= 23 || hour <= 3 { timePool = LATE_NIGHT_SCRIPTS }
        else if hour >= 13 && hour <= 15 { timePool = AFTERNOON_SCRIPTS }
        if !timePool.isEmpty {
            return pickFrom(timePool, idA, idB)
        }
    }

    // Fall back to character-specific pools
    let pool: [ScriptTemplate]
    if hasGC && hasMain {
        pool = MAIN_SHEEP_SCRIPTS + MAIN_GC_SCRIPTS
    } else if hasGC {
        pool = GOOD_COLLEAGUE_SCRIPTS
    } else if hasMain {
        pool = MAIN_SHEEP_SCRIPTS
    } else {
        pool = GENERIC_SCRIPTS
    }

    return pickFrom(pool, idA, idB)
}
