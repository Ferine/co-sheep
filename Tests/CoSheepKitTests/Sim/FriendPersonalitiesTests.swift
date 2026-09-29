import Testing
@testable import CoSheepKit

@Suite("friend personalities")
struct FriendPersonalitiesTests {
    @Test func everyPersonalityHasFifteenQuips() {
        for p in FriendPersonality.allCases {
            let quips = getPersonalityQuips(p)
            #expect(quips.count == 15, "\(p.rawValue)")
            #expect(Set(quips).count == 15)
            #expect(quips == PERSONALITY_QUIPS[p])
        }
        #expect(PERSONALITY_QUIPS.count == 4)
    }

    @Test func quipsAreVerbatim() {
        #expect(getPersonalityQuips(.snarky).first == "I'm not judging. Okay, I'm judging.")
        #expect(getPersonalityQuips(.snarky).last == "At least you're consistent. Consistently questionable.")
        #expect(getPersonalityQuips(.wholesome)[2] == "I believe in ewe!")
        #expect(getPersonalityQuips(.wholesome).last == "You make this desktop brighter!")
        #expect(getPersonalityQuips(.chaotic).first == "CHAOS REIGNS")
        #expect(getPersonalityQuips(.chaotic).last == "ANARCHY! Wait... what's anarchy?")
        #expect(getPersonalityQuips(.passiveAggressive).first == "No, it's fine. I'll just stand here.")
        #expect(getPersonalityQuips(.passiveAggressive).last == "I'll just be over here. Alone. It's fine.")
    }

    @Test func animationBias() {
        #expect(getPersonalityAnimBias(.chaotic) == [.zoom, .spin, .bounce])
        #expect(getPersonalityAnimBias(.wholesome) == [.bounce, .bounce, .spin])
        #expect(getPersonalityAnimBias(.snarky) == [.headshake, .headshake, .vibrate])
        #expect(getPersonalityAnimBias(.passiveAggressive) == [.vibrate, .headshake, .headshake])
    }
}
