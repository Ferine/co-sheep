import Foundation

// Ex-lib.rs — the `#[tauri::command]`s the aux windows call (settings, memory,
// friends, wardrobe, naming, friend-memory), with each `app.emit(...)`
// replaced by the matching `AppEvents.shared` signal.
//
// UI-independent on purpose: the overlay's init calls `getSettings` /
// `getFriends` / `getAccessories` too, and nothing here touches a window.
// (Closing the naming window after `saveSheepName` is the NamingView's job.)

/// The `Err(String)`s the Rust commands returned.
nonisolated struct WindowCommandError: Error, LocalizedError, Equatable, CustomStringConvertible {
    let message: String
    var errorDescription: String? { message }
    var description: String { message }

    /// `add_friend` when the config already holds 4 friends.
    static let maxFriends = WindowCommandError(
        message: "Max 4 friends — the desktop only fits so much wool.")
}

enum WindowCommands {
    /// The flock hard-caps at 5 sheep (4 friends + Good Colleague).
    static let maxFriends = 4

    // MARK: Settings

    /// `get_settings`: the saved config, or defaults when there is none.
    static func getSettings() -> SheepConfig {
        Config.loadConfig() ?? SheepConfig()
    }

    /// `save_settings`: writes the eight settings fields (plus the agent-herd
    /// toggles when given), preserving friends, accessories and MCP settings,
    /// then emits `settingsChanged` with the saved config. Returns the saved
    /// config.
    @discardableResult
    static func saveSettings(
        name: String,
        personality: String,
        intervalSecs: Int,
        language: String,
        breakReminders: Bool,
        easterMode: String,
        summerMode: String,
        weatherLocation: String,
        herdEnabled: Bool? = nil,
        shepherdCommentary: Bool? = nil
    ) throws -> SheepConfig {
        Log.info(
            "app",
            "Saving settings: name=\(name), personality=\(personality), interval=\(intervalSecs)s, language=\(language)")
        // Preserve existing friends and accessories when saving settings
        let config = try Config.updateConfig { c in
            c.name = name
            c.personality = personality
            c.intervalSecs = intervalSecs
            c.language = language
            c.breakReminders = breakReminders
            c.easterMode = easterMode
            c.summerMode = summerMode
            c.weatherLocation = weatherLocation
            if let herdEnabled { c.herdEnabled = herdEnabled }
            if let shepherdCommentary { c.shepherdCommentary = shepherdCommentary }
        }
        AppEvents.shared.settingsChanged.emit(config)
        return config
    }

    // MARK: Friends

    /// `get_friends`: the saved friends, after making sure every friend's
    /// brain (Good Colleague's included) is loaded and the daily decay ran.
    static func getFriends() -> [FriendDef] {
        let friends = Config.loadConfig()?.friends ?? []
        // Ensure friend brains are initialized (including Good Colleague)
        FriendMemory.ensureBrain("good_colleague", "Good Colleague")
        for f in friends {
            FriendMemory.ensureBrain(f.id, f.name)
        }
        FriendMemory.decayAffinities() // daily decay check
        return friends
    }

    /// `add_friend`: mints an id (`friend_<epoch ms>`, suffixed `_1`, `_2`…
    /// on a same-millisecond collision) and a 0.85–1.15 scale, saves the
    /// friend, creates its brain and emits `addFriend`. Throws `.maxFriends`
    /// when 4 friends already exist. Returns the new friend.
    @discardableResult
    static func addFriend(name: String, color: String, personality: String) throws -> FriendDef {
        let baseId = "friend_\(Int(SimClock.nowMs()))"
        let scale = 0.85 + (randF64() * 0.3) // 0.85–1.15
        var id = baseId
        var atCapacity = false
        var added: FriendDef?
        try Config.updateConfig { config in
            // The friends UI disables its button at 4, but the flock also hard
            // caps at 5 sheep (4 + Good Colleague) — enforce here so config
            // can't silently hold friends that never spawn
            if config.friends.count >= maxFriends {
                atCapacity = true
                return
            }
            // Two adds in the same millisecond would otherwise share an id
            // (and thus a brain file)
            var suffix = 1
            while config.friends.contains(where: { $0.id == id }) {
                id = "\(baseId)_\(suffix)"
                suffix += 1
            }
            let friend = FriendDef(
                id: id, name: name, color: color, personality: personality,
                accessories: [], scale: scale)
            config.friends.append(friend)
            added = friend
        }
        if atCapacity { throw WindowCommandError.maxFriends }
        FriendMemory.ensureBrain(id, name)
        AppEvents.shared.addFriend.emit(FriendConfig(
            id: id, name: name,
            color: FriendColor(rawValue: color) ?? .pink,
            personality: FriendPersonality(rawValue: personality),
            accessories: nil, scale: scale))
        Log.info("app", "Added friend: \(name) (\(color), \(personality))")
        // `added` is set whenever `atCapacity` is not.
        return added ?? FriendDef(id: id, name: name, color: color, personality: personality, scale: scale)
    }

    /// lib.rs `rand_f64`: uniform in [0, 1) at 1e-6 resolution.
    private static func randF64() -> Double {
        Double(Int(SimRandom.next() * 1_000_000)) / 1_000_000.0
    }

    /// `save_friend_accessories`: sets one friend's accessories (an unknown
    /// id leaves the config untouched) and emits `friendAccessoriesChanged`.
    static func saveFriendAccessories(id: String, accessories: [String]) throws {
        try Config.updateConfig { config in
            if let i = config.friends.firstIndex(where: { $0.id == id }) {
                config.friends[i].accessories = accessories
            }
        }
        AppEvents.shared.friendAccessoriesChanged.emit((id: id, accessories: accessories))
        Log.info("app", "Friend \(id) accessories saved")
    }

    /// `remove_friend`: drops the friend from the config, deletes its brain
    /// (and scrubs its id from every remaining brain), then emits `removeFriend`.
    static func removeFriend(id: String) throws {
        try Config.updateConfig { config in
            config.friends.removeAll { $0.id == id }
        }
        // Delete the brain and scrub the id from every remaining brain — or the
        // Relationships viewer shows ghosts and affinity maps rot forever
        FriendMemory.removeBrain(id)
        AppEvents.shared.removeFriend.emit(id)
        Log.info("app", "Removed friend: \(id)")
    }

    // MARK: Wardrobe

    /// `get_accessories`: the main sheep's accessory ids.
    static func getAccessories() -> [String] {
        Config.loadConfig()?.accessories ?? []
    }

    /// `save_accessories`: saves the main sheep's accessories and emits
    /// `accessoriesChanged` (with the saved ids; the Tauri event was payload-less).
    static func saveAccessories(_ accessories: [String]) throws {
        try Config.updateConfig { config in
            config.accessories = accessories
        }
        AppEvents.shared.accessoriesChanged.emit(accessories)
        Log.info("app", "Accessories saved")
    }

    // MARK: Memory

    /// `get_memory`: opinions, tallies, stats and today's diary.
    static func getMemory() -> BrainDisplay {
        Memory.getBrainForDisplay()
    }

    /// `get_friend_memory`: one friend's full brain.
    static func getFriendMemory(id: String) -> FriendBrain {
        FriendMemory.getFriendBrain(id)
    }

    /// `get_all_relationships`: a card for every loaded friend brain, by id.
    static func getAllRelationships() -> [String: FriendRelationshipSummary] {
        FriendMemory.getAllRelationships()
    }

    // MARK: Naming

    /// `save_sheep_name`: stores the name (keeping the rest of the config,
    /// creating it on first run) and emits `namingComplete`.
    static func saveSheepName(_ name: String) throws {
        Log.info("app", "Saving sheep name: \(name)")
        try Config.saveConfig(name: name)
        AppEvents.shared.namingComplete.emit(name)
        Log.info("app", "Naming complete, config saved")
    }
}
