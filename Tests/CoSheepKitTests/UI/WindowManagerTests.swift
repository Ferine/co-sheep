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

        /// The area below the title bar / toolbar: what the content can use.
        private func contentSize(_ window: NSWindow) -> NSSize {
            WindowManager.layoutSize(of: window)
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

        // MARK: Liquid Glass chrome

        @Test func contentRunsUnderATitleBarWithNoBackgroundOfItsOwn() {
            withWindows {
                for kind in WindowKind.allCases {
                    withBrainRoot { _ in
                        manager.open(kind)
                        guard let window = manager.window(for: kind) else {
                            Issue.record("\(kind.label) did not open")
                            return
                        }
                        #expect(window.styleMask.contains(.fullSizeContentView), "\(kind.label)")
                        #expect(window.titlebarAppearsTransparent, "\(kind.label)")
                        // The frame also covers the bar; the layout area is what the page was sized for
                        let bar = WindowManager.barHeight(of: window)
                        #expect(bar >= 20, "\(kind.label)")
                        #expect(window.frame.height == kind.size.height + bar, "\(kind.label)")
                        #expect(window.contentView?.frame.size == window.frame.size, "\(kind.label)")
                    }
                }
            }
        }

        @Test func theReadOnlyWindowsPutRefreshInAGlassToolbarAndTheFormsHaveNone() {
            withWindows {
                for kind in WindowKind.allCases {
                    withBrainRoot { _ in
                        manager.open(kind)
                        let toolbar = manager.window(for: kind)?.toolbar
                        switch kind {
                        case .memory, .friendMemory:
                            #expect(toolbar?.items.count == 1, "\(kind.label)")
                        case .settings, .friends, .wardrobe, .naming:
                            #expect(toolbar == nil, "\(kind.label)")
                        }
                    }
                }
            }
        }

        @Test func aToolbarMakesTheBarTallerNotTheContentShorter() {
            withWindows {
                withBrainRoot { _ in
                    manager.open(.settings)
                    manager.open(.memory)
                    let plain = WindowManager.barHeight(of: manager.window(for: .settings)!)
                    let withToolbar = WindowManager.barHeight(of: manager.window(for: .memory)!)
                    #expect(withToolbar > plain)
                    #expect(contentSize(manager.window(for: .memory)!) == WindowKind.memory.size)
                }
            }
        }

        @Test func titleAndSubtitleReachTheWindowThroughTheBridge() {
            #expect(WindowKind.memory.subtitle == "What your sheep knows, believes, and obsesses over")
            #expect(WindowKind.allCases.filter { $0.subtitle != nil } == [.memory])
            withWindows {
                withBrainRoot { _ in
                    manager.open(.memory)
                    manager.open(.settings)
                    // SwiftUI applies them on its next update
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                    #expect(manager.window(for: .memory)?.title == "Sheep's Brain")
                    #expect(manager.window(for: .memory)?.subtitle == WindowKind.memory.subtitle)
                    #expect(manager.window(for: .settings)?.title == "co-sheep Settings")
                    #expect(manager.window(for: .settings)?.subtitle == "")
                }
            }
        }

        @Test func resizableWindowsCannotBeDraggedBelowTheirMinimum() throws {
            try withWindows {
                try withBrainRoot { _ in
                    for kind in [WindowKind.memory, .friendMemory] {
                        manager.open(kind)
                        let window = try #require(manager.window(for: kind))
                        let minSize = try #require(kind.minSize)
                        let bar = WindowManager.barHeight(of: window)
                        // The minimum is for the area below the bar
                        #expect(manager.windowWillResize(window, to: NSSize(width: 50, height: 50))
                            == NSSize(width: minSize.width, height: minSize.height + bar))
                        #expect(manager.windowWillResize(window, to: NSSize(width: 900, height: 50))
                            == NSSize(width: 900, height: minSize.height + bar))
                        #expect(manager.windowWillResize(window, to: NSSize(width: 900, height: 900))
                            == NSSize(width: 900, height: 900))

                        // It holds after SwiftUI has had its say (the hosting
                        // controller zeroes `contentMinSize` on its own)
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                        #expect(manager.windowWillResize(window, to: .zero).width == minSize.width)
                    }
                    // Fixed-size windows and strangers pass through untouched
                    manager.open(.settings)
                    let settings = try #require(manager.window(for: .settings))
                    #expect(manager.windowWillResize(settings, to: NSSize(width: 1, height: 1)) == NSSize(width: 1, height: 1))
                    #expect(manager.windowWillResize(NSWindow(), to: NSSize(width: 2, height: 2)) == NSSize(width: 2, height: 2))
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
