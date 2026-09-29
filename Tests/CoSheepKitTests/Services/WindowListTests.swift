import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// windows.rs and the window half of app_watch.rs had no Rust tests; these pin
// the filtering rules with synthetic CGWindowList rows.
@Suite("window list filtering")
struct WindowListTests {
    private let me: Int32 = 4242

    /// A `CGWindowListCopyWindowInfo` row. Pass nil to leave a key out.
    private func row(
        layer: Int? = 0, pid: Int32? = 100, owner: String? = "Xcode",
        x: Double = 100, y: Double = 100, w: Double = 800, h: Double = 600, bounds: Bool = true
    ) -> [String: Any] {
        var d: [String: Any] = [:]
        if let layer { d[kCGWindowLayer as String] = layer }
        if let pid { d[kCGWindowOwnerPID as String] = pid }
        if let owner { d[kCGWindowOwnerName as String] = owner }
        if bounds {
            d[kCGWindowBounds as String] = CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation as NSDictionary
        }
        return d
    }

    private func rects(_ rows: [[String: Any]]) -> [WindowPlatform] {
        WindowList.visibleWindowRects(in: rows, ownPid: me)
    }

    // MARK: visibleWindowRects (windows.rs)

    @Test func keepsANormalWindowWithItsBounds() {
        #expect(rects([row(x: 10, y: 20, w: 800, h: 600)]) == [WindowPlatform(x: 10, y: 20, w: 800, h: 600)])
    }

    @Test func keepsFrontToBackOrder() {
        let out = rects([row(x: 1), row(x: 2), row(x: 3)])
        #expect(out.map(\.x) == [1, 2, 3])
    }

    @Test func onlyLayerZeroWindowsCount() {
        #expect(rects([row(layer: 25)]).isEmpty)   // menu bar / floating panels
        #expect(rects([row(layer: 3)]).isEmpty)
        #expect(rects([row(layer: -1)]).isEmpty)
        #expect(rects([row(layer: 0)]).count == 1)
    }

    @Test func aRowWithoutALayerKeyIsKept() {
        // windows.rs only rejects rows that have a non-zero layer.
        #expect(rects([row(layer: nil)]).count == 1)
    }

    @Test func ownWindowsAreExcluded() {
        #expect(rects([row(pid: me)]).isEmpty)
        #expect(rects([row(pid: me + 1)]).count == 1)
        #expect(rects([row(pid: nil)]).count == 1)
    }

    @Test func rowsWithoutBoundsAreSkipped() {
        #expect(rects([row(bounds: false)]).isEmpty)
    }

    @Test func tinyWindowsAreSkipped() {
        #expect(rects([row(w: 199, h: 600)]).isEmpty)
        #expect(rects([row(w: 800, h: 99)]).isEmpty)
        #expect(rects([row(w: 200, h: 100)]).count == 1) // exactly the minimum
    }

    @Test func offscreenWindowsAreSkipped() {
        #expect(rects([row(x: -501)]).isEmpty)
        #expect(rects([row(y: -501)]).isEmpty)
        #expect(rects([row(x: 10001)]).isEmpty)
        #expect(rects([row(y: 10001)]).isEmpty)
        #expect(rects([row(x: -500, y: -500)]).count == 1)
        #expect(rects([row(x: 10000, y: 10000)]).count == 1)
    }

    @Test func emptyInfoGivesNoRects() {
        #expect(rects([]).isEmpty)
    }

    // MARK: frontmostAppName (app_watch.rs)

    private func front(_ rows: [[String: Any]]) -> String? {
        WindowList.frontmostAppName(in: rows, ownPid: me)
    }

    @Test func frontmostIsTheFirstQualifyingWindowsOwner() {
        #expect(front([row(owner: "Safari"), row(owner: "Xcode")]) == "Safari")
    }

    @Test func frontmostSkipsOwnAndNonNormalLayers() {
        #expect(front([row(pid: me, owner: "co-sheep"), row(owner: "Xcode")]) == "Xcode")
        #expect(front([row(layer: 25, owner: "Menubar"), row(owner: "Xcode")]) == "Xcode")
    }

    @Test func frontmostSkipsRowsWithoutALayerKey() {
        // Unlike windows.rs, app_watch.rs `continue`s when the layer is missing.
        #expect(front([row(layer: nil, owner: "Ghost"), row(owner: "Xcode")]) == "Xcode")
    }

    @Test func frontmostIgnoresSizeAndBounds() {
        #expect(front([row(owner: "Tiny", w: 10, h: 10)]) == "Tiny")
        #expect(front([row(owner: "NoBounds", bounds: false)]) == "NoBounds")
        #expect(front([row(owner: "Far", x: 99999)]) == "Far")
    }

    @Test func frontmostGivesUpWhenTheFirstQualifyingWindowHasNoUsableName() {
        // `result = cfstring_to_string(...)` then `break`: no fall-through to later windows.
        #expect(front([row(owner: nil), row(owner: "Xcode")]) == nil)
        let longName = String(repeating: "a", count: 256)
        #expect(front([row(owner: longName), row(owner: "Xcode")]) == nil)
        // 255 bytes still fit the 256-byte C buffer (NUL terminator included).
        let maxName = String(repeating: "a", count: 255)
        #expect(front([row(owner: maxName)]) == maxName)
    }

    @Test func frontmostByteLimitCountsUTF8() {
        let twoByteChars = String(repeating: "æ", count: 128) // 256 bytes
        #expect(front([row(owner: twoByteChars)]) == nil)
        let fits = String(repeating: "æ", count: 127) // 254 bytes
        #expect(front([row(owner: fits)]) == fits)
    }

    @Test func frontmostOfNothingIsNil() {
        #expect(front([]) == nil)
        #expect(front([row(pid: me)]) == nil)
    }

    // MARK: live CoreGraphics call

    @Test func liveCallHonoursTheFilters() {
        // Whatever is on screen (possibly nothing when headless), every rect
        // must obey the same rules.
        for r in WindowList.getVisibleWindowRects() {
            #expect(r.w >= 200 && r.h >= 100)
            #expect(r.x >= -500 && r.x <= 10000 && r.y >= -500 && r.y <= 10000)
        }
        _ = WindowList.frontmostAppName() // nil or a name; must not crash
    }
}
