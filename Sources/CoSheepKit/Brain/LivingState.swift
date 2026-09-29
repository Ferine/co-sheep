import Foundation

// Ex-living_state.rs — named JSON blobs the overlay persists between runs
// (`~/.co-sheep/<name>.json`, e.g. "drama" and "spectacles").

enum LivingState {
    /// Names are file stems: non-empty, `[a-z0-9_-]` only (no path tricks).
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { b in
            (97...122).contains(b) || (48...57).contains(b) || b == 95 || b == 45
        }
    }

    /// Load a named JSON state blob. Returns `.null` if missing/invalid.
    static func loadState(_ name: String) -> JSONValue {
        guard validName(name) else { return .null }
        let path = Paths.livingState(name)
        guard let data = try? Data(contentsOf: path) else { return .null }
        guard let value = try? JSONFile.decoder().decode(JSONValue.self, from: data) else {
            // Invalid JSON: keep it aside rather than letting the next save
            // (drama / spectacle state) overwrite it.
            JSONFile.quarantine(path, reason: "invalid JSON")
            return .null
        }
        return value
    }

    /// Persist a named JSON state blob to `~/.co-sheep/<name>.json`.
    static func saveState(_ name: String, _ value: JSONValue) {
        guard validName(name) else {
            Log.info("state", "error: living_state: rejected name '\(name)'")
            return
        }
        try? JSONFile.write(value, to: Paths.livingState(name))
    }
}

extension Paths {
    /// `<name>.json` in the root, for `LivingState` (callers validate the name).
    static func livingState(_ name: String) -> URL { file("\(name).json") }
}
