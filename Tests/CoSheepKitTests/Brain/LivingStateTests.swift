import Foundation
import Testing
@testable import CoSheepKit

// living_state.rs had no tests; these pin its behavior.
extension BrainTests {
    @Suite("living state")
    struct LivingStateTests {
        @Test func nameValidationAllowsOnlyLowercaseDigitsUnderscoreDash() {
            for ok in ["drama", "spectacles", "a-b_c9", "0"] { #expect(LivingState.validName(ok)) }
            for bad in ["", "Drama", "../etc/passwd", "a.b", "a b", "æ", "a/b"] {
                #expect(!LivingState.validName(bad))
            }
        }

        @Test func missingAndInvalidStatesLoadAsNull() throws {
            try withBrainRoot { _ in
                #expect(LivingState.loadState("drama") == .null)
                #expect(LivingState.loadState("../config") == .null)
                try write("{ broken", to: Paths.file("drama.json"))
                #expect(LivingState.loadState("drama") == .null)
            }
        }

        @Test func saveThenLoadRoundTrips() {
            withBrainRoot { _ in
                let value: JSONValue = .object([
                    "version": .number(1),
                    "pairs": .array([.object(["a": .string("x"), "affinity": .number(-2.5)]), .null, .bool(true)]),
                ])
                LivingState.saveState("drama", value)
                #expect(FileManager.default.fileExists(atPath: Paths.file("drama.json").path))
                #expect(LivingState.loadState("drama") == value)
                LivingState.saveState("drama", .null)
                #expect(LivingState.loadState("drama") == .null)
            }
        }

        @Test func rejectedNamesWriteNothing() {
            withBrainRoot { root in
                LivingState.saveState("../escape", .object([:]))
                LivingState.saveState("Bad", .object([:]))
                LivingState.saveState("", .object([:]))
                let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                #expect(files.isEmpty)
                #expect(!FileManager.default.fileExists(
                    atPath: root.deletingLastPathComponent().appendingPathComponent("escape.json").path))
            }
        }

        @Test func loadsAStateFileWrittenByTheRustApp() throws {
            try withBrainRoot { _ in
                try write(#"{"version": 1, "pairs": {"a|b": {"state": "feud", "since": 1780000000000}}}"#,
                          to: Paths.file("drama.json"))
                let v = LivingState.loadState("drama")
                #expect(v["version"]?.doubleValue == 1)
                #expect(v["pairs"]?["a|b"]?["state"]?.stringValue == "feud")
                #expect(v["pairs"]?["a|b"]?["since"]?.doubleValue == 1_780_000_000_000)
            }
        }
    }
}
