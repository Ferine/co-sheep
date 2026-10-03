import AppKit
import Foundation
import Testing
@testable import CoSheepKit

// Real NSWindows: needs a window server (any logged-in Mac session).
extension BrainTests {
    @Suite("window manager")
    struct WindowManagerTests {
        private let manager = WindowManager.shared

        /// Runs `body`, then closes every aux window so tests never leak windows.
        private func withWindows<T>(_ body: () throws -> T) rethrows -> T {
            _ = NSApplication.shared
            defer { for kind in WindowKind.allCases { manager.close(kind) } }
            return try body()
        }

        private func contentSize(_ window: NSWindow) -> NSSize {
            window.contentRect(forFrameRect: window.frame).size
        }

        @Test func everyKindOpensWithTheTauriTitleSizeAndResizability() {
            let expected: [(WindowKind, String, NSSize, Bool)] = [
                (.naming, "Name your sheep!", NSSize(width: 380, height: 180), false),
                (.memory, "Sheep's Brain", NSSize(width: 550, height: 600), true),
                (.settings, "co-sheep Settings", NSSize(width: 420, height: 600), false),
                (.friends, "Manage Friends", NSSize(width: 400, height: 550), false),
                (.wardrobe, "Wardrobe", NSSize(width: 400, height: 580), false),
                (.friendMemory, "Friend Relationships", NSSize(width: 420, height: 500), true),
            ]
            #expect(expected.count == WindowKind.allCases.count)
            withWindows {
                for (kind, title, size, resizable) in expected {
                    withBrainRoot { _ in
                        manager.open(kind)
                        guard let window = manager.window(for: kind) else {
                            Issue.record("\(kind.label) did not open")
                            return
                        }
                        #expect(window.title == title)
                        #expect(contentSize(window) == size)
                        #expect(window.styleMask.contains(.resizable) == resizable)
                        #expect(window.styleMask.contains(.titled))
                        #expect(window.styleMask.contains(.closable))
                        #expect(window.level == .floating)
                        #expect(window.isVisible)
                    }
                }
            }
        }

        @Test func tauriWindowLabelsAreKept() {
            #expect(WindowKind.allCases.map(\.label) == [
                "settings", "memory", "friends", "wardrobe", "naming", "friend_memory",
            ])
        }

        @Test func openingAnOpenKindReusesTheWindow() {
            withBrainRoot { _ in
                withWindows {
                    manager.open(.wardrobe)
                    let first = manager.window(for: .wardrobe)
                    #expect(first != nil)
                    manager.open(.wardrobe)
                    #expect(manager.window(for: .wardrobe) === first)
                    #expect(NSApp.windows.filter { $0.title == "Wardrobe" }.count == 1)
                }
            }
        }

        @Test func kindsHaveIndependentWindows() {
            withBrainRoot { _ in
                withWindows {
                    manager.open(.settings)
                    manager.open(.memory)
                    #expect(manager.window(for: .settings) !== manager.window(for: .memory))
                    manager.close(.settings)
                    #expect(!manager.isOpen(.settings))
                    #expect(manager.isOpen(.memory))
                }
            }
        }

        @Test func closingForgetsTheWindowSoTheNextOpenIsFresh() {
            withBrainRoot { _ in
                withWindows {
                    manager.open(.friends)
                    let first = manager.window(for: .friends)
                    manager.close(.friends)
                    #expect(manager.window(for: .friends) == nil)
                    manager.open(.friends)
                    let second = manager.window(for: .friends)
                    #expect(second != nil)
                    #expect(second !== first)
                }
            }
        }

        @Test func closingAWindowThroughTheUserPathForgetsItToo() {
            withBrainRoot { _ in
                withWindows {
                    manager.open(.naming)
                    manager.window(for: .naming)?.performClose(nil)
                    #expect(!manager.isOpen(.naming))
                }
            }
        }

        @Test func closingAnUnopenedKindIsHarmless() {
            withWindows {
                manager.close(.settings)
                #expect(!manager.isOpen(.settings))
            }
        }

        @Test func reopeningAFormKeepsItsEditsAndAFreshWindowReloads() throws {
            try withBrainRoot { _ in
                try withWindows {
                    var config = SheepConfig()
                    config.name = "First"
                    try Config.writeConfig(config)

                    manager.open(.settings)
                    let model = try #require(manager.model(for: .settings) as? SettingsModel)
                    #expect(model.name == "First")

                    model.name = "Typed"
                    config.name = "Second"
                    try Config.writeConfig(config)
                    manager.open(.settings) // reuse: brought to the front, edits kept
                    #expect(manager.model(for: .settings) === model)
                    #expect(model.name == "Typed")

                    manager.close(.settings)
                    config.name = "Third"
                    try Config.writeConfig(config)
                    manager.open(.settings) // fresh window, fresh model
                    let fresh = try #require(manager.model(for: .settings) as? SettingsModel)
                    #expect(fresh.name == "Third")
                }
            }
        }

        @Test func readOnlyWindowsAlsoRefreshWhenTheyBecomeKey() throws {
            try withBrainRoot { _ in
                try withWindows {
                    manager.open(.memory)
                    let model = try #require(manager.model(for: .memory) as? BrainModel)
                    #expect(model.display.totalComments == 0)

                    Memory.recordComment()
                    let window = try #require(manager.window(for: .memory))
                    manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
                    #expect(model.display.totalComments == 1)
                }
            }
        }

        @Test func formsAreNotReloadedWhenTheyBecomeKeyAgain() throws {
            try withBrainRoot { _ in
                try withWindows {
                    var config = SheepConfig()
                    config.name = "Saved"
                    try Config.writeConfig(config)
                    manager.open(.settings)
                    let model = try #require(manager.model(for: .settings) as? SettingsModel)

                    model.name = "Half-typed edit"
                    let window = try #require(manager.window(for: .settings))
                    manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
                    #expect(model.name == "Half-typed edit")
                }
            }
        }

        @Test func namingCloseAfterSaveClosesTheWindow() throws {
            try withBrainRoot { _ in
                try withWindows {
                    manager.open(.naming)
                    let model = try #require(manager.model(for: .naming) as? NamingModel)
                    model.name = "Dolly"
                    #expect(model.submit())
                    manager.close(.naming)
                    #expect(!manager.isOpen(.naming))
                    #expect(Config.getSheepName() == "Dolly")
                }
            }
        }
    }
}
