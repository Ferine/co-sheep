import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import CoSheepKit

// The aux windows' models: the page logic that isn't just layout.
extension BrainTests {
    @Suite("window models")
    struct WindowModelTests {
        private func seed(_ mutate: (inout SheepConfig) -> Void = { _ in }) throws {
            var config = SheepConfig()
            config.name = "Woolly"
            mutate(&config)
            try Config.writeConfig(config)
        }

        private func opinion(_ topic: String, seen: Int, category: String = "habit") -> Opinion {
            Opinion(
                topic: topic, opinion: "About \(topic).", timesSeen: seen,
                firstSeen: "2026-01-01", lastSeen: "2026-01-02 10:00", category: category)
        }

        // MARK: Settings

        @Test func intervalLabelMatchesTheSettingsPage() {
            #expect(SettingsModel.formatInterval(30) == "30s")
            #expect(SettingsModel.formatInterval(50) == "50s")
            #expect(SettingsModel.formatInterval(60) == "1 min")
            #expect(SettingsModel.formatInterval(150) == "2.5 min")
            #expect(SettingsModel.formatInterval(70) == "1.2 min")
            #expect(SettingsModel.formatInterval(600) == "10 min")
        }

        @Test func intervalSnapsToTheSliderRangeAndStep() {
            #expect(SettingsModel.snapInterval(150) == 150)
            #expect(SettingsModel.snapInterval(10) == 30)
            #expect(SettingsModel.snapInterval(999) == 600)
            #expect(SettingsModel.snapInterval(44) == 40)
            #expect(SettingsModel.snapInterval(45) == 50)
        }

        @Test func personalityDescriptionsAreVerbatim() {
            let m = SettingsModel()
            m.personality = "snarky"
            #expect(m.personalityDescription == "Judgmental and opinionated, like self-aware Clippy.")
            m.personality = "wholesome"
            #expect(m.personalityDescription == "Supportive and encouraging, your cozy desk buddy.")
            m.personality = "chaotic"
            #expect(m.personalityDescription == "Unhinged energy, zero filter, maximum sheep puns.")
            m.personality = "passive-aggressive"
            #expect(m.personalityDescription == "Master of backhanded compliments and loud sighs.")
            m.personality = "something-else"
            #expect(m.personalityDescription == "")
        }

        @Test func settingsOffersEveryOptionOfThePage() {
            #expect(SettingsModel.personalities.map(\.value) == ["snarky", "wholesome", "chaotic", "passive-aggressive"])
            #expect(SettingsModel.languages.map(\.value) == [
                "nynorsk", "bokmål", "english", "swedish", "danish", "german", "french", "spanish", "japanese", "korean",
            ])
            #expect(SettingsModel.easterModes.map(\.label) == ["Auto (seasonal only)", "Always on", "Always off"])
            #expect(SettingsModel.summerModes.map(\.label) == ["Auto (summer weather only)", "Always on", "Always off"])
        }

        @Test func unknownSavedValueStaysSelectable() {
            let base = SettingsModel.languages
            #expect(ChoiceOption.including("german", in: base) == base)
            #expect(ChoiceOption.including("", in: base) == base)
            let extended = ChoiceOption.including("klingon", in: base)
            #expect(extended.count == base.count + 1)
            #expect(extended.last == ChoiceOption(value: "klingon", label: "klingon"))
        }

        @Test func settingsModelLoadsTheSavedConfig() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.personality = "chaotic"
                    $0.intervalSecs = 90
                    $0.language = "german"
                    $0.weatherLocation = "Oslo"
                    $0.easterMode = "on"
                    $0.summerMode = "off"
                    $0.breakReminders = false
                }
                let m = SettingsModel()
                m.reload()
                #expect(m.name == "Woolly")
                #expect(m.intervalSecs == 90)
                #expect(m.intervalLabel == "1.5 min")
                #expect(m.personality == "chaotic")
                #expect(m.language == "german")
                #expect(m.weatherLocation == "Oslo")
                #expect(m.easterMode == "on")
                #expect(m.summerMode == "off")
                #expect(m.breakReminders == false)
            }
        }

        @Test func settingsModelWithoutAConfigShowsTheDefaults() {
            withBrainRoot { _ in
                let m = SettingsModel()
                m.reload()
                #expect(m.name == "Sheep")
                #expect(m.intervalSecs == 150)
                #expect(m.personality == "snarky")
                #expect(m.language == "nynorsk")
                #expect(m.easterMode == "auto")
                #expect(m.summerMode == "auto")
                #expect(m.breakReminders)
            }
        }

        @Test func savingSettingsTrimsAndDefaultsTheName() throws {
            try withBrainRoot { _ in
                try seed()
                let events = Captured(AppEvents.shared.settingsChanged)
                defer { events.stop() }
                let m = SettingsModel()
                m.reload()
                m.name = "   "
                m.weatherLocation = "  Bergen \n"
                m.intervalSecs = 240
                m.save()

                let saved = try #require(Config.loadConfig())
                #expect(saved.name == "Sheep")
                #expect(saved.weatherLocation == "Bergen")
                #expect(saved.intervalSecs == 240)
                #expect(events.values == [saved])
                #expect(m.saved.isOn)
                #expect(m.errorMessage == nil)
            }
        }

        @Test func savingSettingsReportsAWriteFailure() throws {
            try withBrainRoot { _ in
                try write("{ not json", to: Paths.config)
                let m = SettingsModel()
                m.save()
                #expect(m.errorMessage != nil)
                #expect(!m.saved.isOn)
            }
        }

        // MARK: Brain

        @Test func opinionsAreSortedMostSeenFirstKeepingStoredOrderOnTies() {
            let m = BrainModel()
            m.display.opinions = [
                opinion("a", seen: 1), opinion("b", seen: 5), opinion("c", seen: 1), opinion("d", seen: 3),
                opinion("e", seen: 5),
            ]
            #expect(m.sortedOpinions.map(\.topic) == ["b", "e", "d", "a", "c"])
        }

        @Test func hotFromFiveSightings() {
            #expect(!BrainModel.isHot(opinion("a", seen: 4)))
            #expect(BrainModel.isHot(opinion("a", seen: 5)))
        }

        @Test func blankCategoryIsAnOpinion() {
            #expect(BrainModel.category(opinion("a", seen: 1, category: "")) == "opinion")
            #expect(BrainModel.category(opinion("a", seen: 1, category: "fact")) == "fact")
        }

        @Test func talliesAreSortedBiggestFirstThenByKey() {
            let m = BrainModel()
            m.display.todayCounts = ["app:mail": 2, "app:code": 9, "app:browser": 2]
            #expect(m.sortedCounts.map(\.key) == ["app:code", "app:browser", "app:mail"])
            #expect(m.sortedCounts.map(\.count) == [9, 2, 2])
        }

        @Test func diaryHeadingsAndCommentLabelsAreStyled() {
            #expect(BrainModel.journalSegments("# September 29, 2026 — Woolly's Diary")
                == [.init(text: "# September 29, 2026 — Woolly's Diary", style: .heading)])
            #expect(BrainModel.journalSegments("## 08:17 PM") == [.init(text: "## 08:17 PM", style: .heading)])
            // "#hashtag" and "###" are not headings.
            #expect(BrainModel.journalSegments("#hashtag") == [.init(text: "#hashtag", style: .plain)])
            #expect(BrainModel.journalSegments("### deep") == [.init(text: "### deep", style: .plain)])
            #expect(BrainModel.journalSegments("**Comment**: Baaa") == [
                .init(text: "Comment:", style: .commentLabel), .init(text: " Baaa", style: .plain),
            ])
            #expect(BrainModel.journalSegments("a **Comment**: b **Comment**: c") == [
                .init(text: "a ", style: .plain), .init(text: "Comment:", style: .commentLabel),
                .init(text: " b ", style: .plain), .init(text: "Comment:", style: .commentLabel),
                .init(text: " c", style: .plain),
            ])
            #expect(BrainModel.journalSegments("*My human petted me!*")
                == [.init(text: "*My human petted me!*", style: .plain)])
        }

        @Test func aHeadingLineIsNotScannedForCommentLabels() {
            #expect(BrainModel.journalSegments("## **Comment**: x")
                == [.init(text: "## **Comment**: x", style: .heading)])
        }

        @Test func diaryTextKeepsEveryLineAndRewritesTheCommentMarker() throws {
            let text = try #require(BrainModel.journalText("# Title\n\n## 08:17 PM\n**Comment**: Baaa\n"))
            #expect(String(text.characters) == "# Title\n\n## 08:17 PM\nComment: Baaa\n")
        }

        @Test func aBlankDiaryHasNoText() {
            #expect(BrainModel.journalText("") == nil)
            #expect(BrainModel.journalText("  \n \t\n") == nil)
        }

        @Test func brainModelLoadsTheMemory() throws {
            try withBrainRoot { _ in
                try seed()
                try Memory.saveOpinion(topic: "tabs", opinion: "Too many.", category: "pattern")
                Memory.recordComment()
                let m = BrainModel()
                m.reload()
                #expect(m.display.opinions.map(\.topic) == ["tabs"])
                #expect(m.display.totalComments == 1)
            }
        }

        // MARK: Friends

        @Test func friendChipsReadLikeThePage() {
            #expect(FriendsModel.chipTitle("party_hat") == "party hat")
            #expect(FriendsModel.chipTitle("pirate_patch") == "pirate patch")
            #expect(FriendsModel.chipTitle("halo") == "halo")
            #expect(FriendsModel.personalities.map(\.value) == ["wholesome", "snarky", "chaotic", "passive-aggressive"])
            #expect(FriendsModel.colors.map(\.value) == ["pink", "green", "gold", "purple", "orange"])
        }

        @Test func friendsModelShowsTheFlockAndTheCapacityState() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = (1...3).map { FriendDef(id: "f\($0)", name: "F\($0)", color: "pink") } }
                let m = FriendsModel()
                m.reload()
                #expect(m.friends.map(\.id) == ["f1", "f2", "f3"])
                #expect(!m.atCapacity)
                #expect(m.addButtonTitle == "Add Friend")

                m.newName = "F4"
                m.add()
                #expect(m.friends.count == 4)
                #expect(m.atCapacity)
                #expect(m.addButtonTitle == "Max friends reached")
                #expect(!m.canAdd)
            }
        }

        @Test func addingAFriendClearsTheFormAndConfirms() throws {
            try withBrainRoot { _ in
                try seed()
                let events = Captured(AppEvents.shared.addFriend)
                defer { events.stop() }
                let m = FriendsModel()
                m.reload()
                #expect(!m.canAdd)
                m.newName = "  Fluffy  "
                m.newColor = "purple"
                m.newPersonality = "chaotic"
                #expect(m.canAdd)
                m.add()

                #expect(m.newName == "")
                #expect(m.status == "Fluffy is parachuting in!")
                #expect(!m.statusIsError)
                let saved = try #require(Config.loadConfig()?.friends.first)
                #expect(saved.name == "Fluffy")
                #expect(saved.color == "purple")
                #expect(saved.personality == "chaotic")
                #expect(events.values.first?.color == .purple)
            }
        }

        @Test func addingWithABlankNameDoesNothing() throws {
            try withBrainRoot { _ in
                try seed()
                let m = FriendsModel()
                m.reload()
                m.newName = "   "
                m.add()
                #expect(Config.loadConfig()?.friends.isEmpty == true)
                #expect(m.status == "")
            }
        }

        @Test func friendNamesAreLimitedToTwentyCharacters() {
            let m = FriendsModel()
            m.newName = String(repeating: "x", count: 30)
            #expect(m.newName.count == 20)
        }

        @Test func removingAFriendNeedsConfirmation() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [FriendDef(id: "f1", name: "Fluffy", color: "pink")] }
                let events = Captured(AppEvents.shared.removeFriend)
                defer { events.stop() }
                let m = FriendsModel()
                m.reload()

                m.pendingRemoval = m.friends[0]
                #expect(Config.loadConfig()?.friends.count == 1) // nothing happens until confirmed
                m.confirmRemoval()

                #expect(m.friends.isEmpty)
                #expect(m.pendingRemoval == nil)
                #expect(m.status == "Friend removed!")
                #expect(Config.loadConfig()?.friends.isEmpty == true)
                #expect(events.values == ["f1"])
            }
        }

        @Test func accessoryChipsToggleInInsertionOrderAndSave() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [FriendDef(id: "f1", name: "Fluffy", color: "pink", accessories: ["crown"])] }
                let events = Captured(AppEvents.shared.friendAccessoriesChanged)
                defer { events.stop() }
                let m = FriendsModel()
                m.reload()
                #expect(m.isOn("crown", for: "f1"))
                #expect(!m.isOn("halo", for: "f1"))

                m.toggle("halo", for: "f1")
                m.toggle("crown", for: "f1")
                m.toggle("cape", for: "f1")
                #expect(m.drafts["f1"] == ["halo", "cape"])

                m.saveAccessories(for: m.friends[0])
                #expect(Config.loadConfig()?.friends.first?.accessories == ["halo", "cape"])
                #expect(events.values.first?.accessories == ["halo", "cape"])
                #expect(m.status == "Accessories saved!")
            }
        }

        // MARK: Wardrobe

        @Test func wardrobeOffersTheEighteenAccessoriesInPageOrder() {
            let m = WardrobeModel()
            #expect(m.accessories.map(\.id) == WARDROBE_ACCESSORY_IDS)
            #expect(m.accessories.count == 18)
            #expect(m.accessories.first?.name == "Party Hat")
            #expect(m.accessories.first { $0.id == "pirate_patch" }?.name == "Eye Patch")
            #expect(m.accessories.first { $0.id == "cape" }?.category == .neck)
        }

        @Test func wardrobeKeepsSelectionInInsertionOrderAndKeepsUnknownIds() throws {
            try withBrainRoot { _ in
                try seed { $0.accessories = ["halo", "bunny_ears", "halo"] }
                let events = Captured(AppEvents.shared.accessoriesChanged)
                defer { events.stop() }
                let m = WardrobeModel()
                m.reload()
                #expect(m.selected == ["halo", "bunny_ears"]) // deduped like a Set

                m.toggle("crown")
                m.toggle("halo")
                m.toggle("halo")
                #expect(m.selected == ["bunny_ears", "crown", "halo"])

                m.save()
                #expect(WindowCommands.getAccessories() == ["bunny_ears", "crown", "halo"])
                #expect(events.values == [["bunny_ears", "crown", "halo"]])
                #expect(m.saved.isOn)
            }
        }

        // MARK: Naming

        @Test func namingIgnoresABlankName() {
            withBrainRoot { _ in
                let events = Captured(AppEvents.shared.namingComplete)
                defer { events.stop() }
                let m = NamingModel()
                m.name = "   "
                #expect(!m.submit())
                #expect(Config.needsOnboarding())
                #expect(events.values.isEmpty)
            }
        }

        @Test func namingSavesTheTrimmedNameAndAsksToClose() {
            withBrainRoot { _ in
                let events = Captured(AppEvents.shared.namingComplete)
                defer { events.stop() }
                let m = NamingModel()
                m.name = "  Dolly "
                #expect(m.submit())
                #expect(Config.getSheepName() == "Dolly")
                #expect(events.values == ["Dolly"])
            }
        }

        @Test func namingKeepsTheWindowOpenWhenTheSaveFails() throws {
            try withBrainRoot { _ in
                try write("{ not json", to: Paths.config)
                let m = NamingModel()
                m.name = "Dolly"
                #expect(!m.submit())
                #expect(m.errorMessage != nil)
            }
        }

        // MARK: Friend memory

        @Test func moodLabelsCarryTheirEmoji() {
            #expect(FriendMemoryModel.moodLabel("happy") == "\u{1F60A} happy")
            #expect(FriendMemoryModel.moodLabel("grumpy") == "\u{1F612} grumpy")
            #expect(FriendMemoryModel.moodLabel("sleepy") == "\u{1F634} sleepy")
            #expect(FriendMemoryModel.moodLabel("excited") == "\u{1F929} excited")
            #expect(FriendMemoryModel.moodLabel("puzzled") == " puzzled")
        }

        @Test func affinityBarsClampAndColor() {
            #expect(FriendMemoryModel.affinityFraction(-10) == 0)
            #expect(FriendMemoryModel.affinityFraction(100) == 1)
            #expect(FriendMemoryModel.affinityFraction(45) == 0.5)
            #expect(FriendMemoryModel.affinityFraction(-50) == 0)
            #expect(FriendMemoryModel.affinityFraction(500) == 1)
            #expect(FriendMemoryModel.affinityColor(-1) == UITheme.accent)
            #expect(FriendMemoryModel.affinityColor(0) == Color(white: 0x55 / 255))
            #expect(FriendMemoryModel.affinityColor(10) == Color(white: 0x55 / 255))
            #expect(FriendMemoryModel.affinityColor(11) == UITheme.success)
            #expect(FriendMemoryModel.affinityColor(30) == UITheme.success)
            #expect(FriendMemoryModel.affinityColor(31) == Color(red: 1, green: 0xd7 / 255, blue: 0))
        }

        @Test func friendMemoryShowsCardsInKeyOrderAndTheSelectedDetail() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.friends = [
                        FriendDef(id: "friend_b", name: "Bjørn", color: "gold"),
                        FriendDef(id: "friend_a", name: "Anna", color: "green"),
                    ]
                }
                _ = WindowCommands.getFriends()
                FriendMemory.recordConversation("friend_a", "friend_b", "tabs")
                FriendMemory.recordConversation("friend_a", "good_colleague", "meetings")

                let m = FriendMemoryModel()
                m.reload()
                #expect(m.sortedIds == ["friend_a", "friend_b", "good_colleague"])
                #expect(m.brain == nil)

                m.select("friend_a")
                #expect(m.brain?.name == "Anna")
                // Affinities in key order, named after the other friend.
                #expect(m.relationships.map(\.id) == ["friend_b", "good_colleague"])
                #expect(m.relationships.map(\.name) == ["Bjørn", "Good Colleague"])
                #expect(m.relationships.map(\.value) == [1, 1])
            }
        }

        @Test func friendMemoryListsTheFifteenNewestMemoriesNewestFirst() {
            withBrainRoot { _ in
                FriendMemory.ensureBrain("f", "F")
                FriendMemory.ensureBrain("g", "G")
                for i in 1...20 { FriendMemory.recordConversation("f", "g", "t\(i)") }
                let m = FriendMemoryModel()
                m.reload()
                m.select("f")
                // The brain keeps 20; the page shows the newest 15, newest first.
                #expect(m.brain?.memories.count == 20)
                #expect(m.recentMemories.count == 15)
                #expect(m.recentMemories.first?.text == "Talked with G about t20")
                #expect(m.recentMemories.last?.text == "Talked with G about t6")
            }
        }

        @Test func friendMemoryHidesTheFriendsOwnAffinityRow() {
            withBrainRoot { _ in
                FriendMemory.ensureBrain("f", "F")
                FriendMemory.recordPet("f")
                FriendMemory.recordConversation("f", "f", "itself") // affinity toward itself
                let m = FriendMemoryModel()
                m.reload()
                m.select("f")
                #expect(m.brain?.relationships["f"] != nil)
                #expect(m.relationships.map(\.id) == ["main"])
                // No card for "main": the row falls back to its id.
                #expect(m.relationships.first?.name == "main")
            }
        }

        @Test func reloadingDropsTheSelectionOfAFriendWhoLeft() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [FriendDef(id: "f1", name: "Fluffy", color: "pink")] }
                _ = WindowCommands.getFriends()
                let m = FriendMemoryModel()
                m.reload()
                m.select("f1")
                #expect(m.brain?.id == "f1")

                try WindowCommands.removeFriend(id: "f1")
                m.reload()
                #expect(m.selectedId == nil)
                #expect(m.brain == nil)
                #expect(m.sortedIds == ["good_colleague"])
            }
        }

        // MARK: Sheep preview

        /// Raw pixels of `image`, for comparisons.
        private func pixels(_ image: CGImage) -> Data? {
            image.dataProvider?.data as Data?
        }

        @Test func sheepPreviewRendersTheRealSprite() throws {
            let image = try #require(SheepPreview.image(accessories: [], scale: 2))
            #expect(image.width == 400)
            #expect(image.height == 260)
            // The sprite is opaque somewhere; the corners are empty.
            let data = try #require(pixels(image))
            #expect(data.contains { $0 != 0 })
            #expect(data.prefix(4).allSatisfy { $0 == 0 })
        }

        @Test func sheepPreviewShowsTheSelectedAccessories() throws {
            let plain = try #require(SheepPreview.image(accessories: [], scale: 2))
            let crowned = try #require(SheepPreview.image(accessories: ["crown"], scale: 2))
            let more = try #require(SheepPreview.image(accessories: ["crown", "sunglasses"], scale: 2))
            #expect(pixels(plain) != pixels(crowned))
            #expect(pixels(crowned) != pixels(more))
            // Ids the registry doesn't know draw nothing extra.
            let unknown = try #require(SheepPreview.image(accessories: ["nope"], scale: 2))
            #expect(pixels(plain) == pixels(unknown))
        }

        @Test func everyWardrobeAccessoryDrawsSomethingOnThePreview() throws {
            let plain = SheepPreview.ops(accessories: [])
            for id in WARDROBE_ACCESSORY_IDS {
                let ops = SheepPreview.ops(accessories: [id])
                #expect(ops.count > plain.count, "\(id) should add draw ops")
            }
        }
    }
}
