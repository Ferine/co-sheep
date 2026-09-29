import Foundation

// Ex-friend-personalities.ts. Quips are verbatim.

nonisolated enum FriendPersonalityData {
    static let SNARKY_QUIPS = [
        "I'm not judging. Okay, I'm judging.",
        "Is this what productivity looks like?",
        "*stares disapprovingly*",
        "I've seen better screensavers.",
        "Don't mind me. Just observing.",
        "*raises eyebrow*",
        "Riveting. Truly.",
        "Is that all you've got?",
        "I've formed opinions. None of them good.",
        "The bar was low. You limboed under it.",
        "Bold strategy. Let's see how it plays out.",
        "*slow clap*",
        "Sure, that's one way to do it.",
        "I'm not mad, I'm disappointed.",
        "At least you're consistent. Consistently questionable.",
    ]

    static let WHOLESOME_QUIPS = [
        "You're doing great!",
        "*happy bounce*",
        "I believe in ewe!",
        "Today is a good day to be a sheep!",
        "*nuzzles happily*",
        "I'm so glad we're friends!",
        "You look lovely today!",
        "*contented sigh*",
        "Life is beautiful from this desktop.",
        "Group hug? No? Okay, just a bounce then!",
        "I appreciate you!",
        "*wiggles ears joyfully*",
        "Every day is an adventure!",
        "Friendship is magic! Wait, wrong show.",
        "You make this desktop brighter!",
    ]

    static let CHAOTIC_QUIPS = [
        "CHAOS REIGNS",
        "What if we're ALL desktop pets?!",
        "I ATE A PIXEL",
        "WHAT IF THE SCREEN IS WATCHING US BACK",
        "I can hear colors right now",
        "*vibrates with uncontainable energy*",
        "ZOOM ZOOM ZOOM",
        "I forgot what I was doing! PERFECT!",
        "Let's rearrange all the icons!",
        "THE VOID STARES BACK AND IT'S HILARIOUS",
        "I have a plan! I forgot the plan! NEW PLAN!",
        "Everything is fine! EVERYTHING!",
        "Who needs sleep when you have PIXELS?!",
        "Reality is a suggestion I choose to ignore!",
        "ANARCHY! Wait... what's anarchy?",
    ]

    static let PA_QUIPS = [
        "No, it's fine. I'll just stand here.",
        "*sighs meaningfully*",
        "Oh, you're STILL here?",
        "I mean, I COULD say something, but why bother.",
        "Don't mind me. Nobody does.",
        "Oh, were you talking to me? I assumed not.",
        "It's fine. Everything's fine.",
        "*pointedly looks away*",
        "I'm sure someone appreciates me. Somewhere.",
        "No no, please. Continue ignoring me.",
        "Must be nice to be the MAIN sheep.",
        "Some of us are just background characters, I guess.",
        "*dramatically sighs*",
        "Oh, another conversation I wasn't invited to? Cool.",
        "I'll just be over here. Alone. It's fine.",
    ]
}

nonisolated let PERSONALITY_QUIPS: [FriendPersonality: [String]] = [
    .snarky: FriendPersonalityData.SNARKY_QUIPS,
    .wholesome: FriendPersonalityData.WHOLESOME_QUIPS,
    .chaotic: FriendPersonalityData.CHAOTIC_QUIPS,
    .passiveAggressive: FriendPersonalityData.PA_QUIPS,
]

nonisolated func getPersonalityQuips(_ p: FriendPersonality) -> [String] {
    PERSONALITY_QUIPS[p] ?? FriendPersonalityData.WHOLESOME_QUIPS
}

nonisolated func getPersonalityAnimBias(_ p: FriendPersonality) -> [SheepAnimation] {
    switch p {
    case .chaotic:
        [.zoom, .spin, .bounce]
    case .wholesome:
        [.bounce, .bounce, .spin]
    case .snarky:
        [.headshake, .headshake, .vibrate]
    case .passiveAggressive:
        [.vibrate, .headshake, .headshake]
    }
}
