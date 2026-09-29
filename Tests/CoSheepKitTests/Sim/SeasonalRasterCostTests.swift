import CoreGraphics
import Testing
@testable import CoSheepKit

extension BrainTests {
    /// Regression: seasonal petals/seeds/butterflies/flowers used to live in
    /// screen-wide tiles re-rasterized every frame (~a full screen of pixels).
    @Suite("seasonal raster cost")
    struct SeasonalRasterCostTests {
        @Test func seasonsDoNotRasterizeTheScreenEveryFrame() {
            withBrainRoot { _ in
                let savedRandom = SimRandom.source
                defer { SimRandom.source = savedRandom }
                SimRandom.source = SimRandom.seeded(7)

                let w = 2560.0, h = 1440.0
                let flock = Flock(w, h)
                flock.setEasterMode(.on)
                flock.setSummerMode(.on)
                let canvas = Canvas()
                let tiles = CanvasTileLayer()
                let viewport = CGRect(x: 0, y: 0, width: w, height: h)

                var total = 0
                let frames = 240
                for i in 0..<(frames + 60) {
                    flock.update(16)
                    canvas.beginFrame()
                    flock.draw(canvas)
                    tiles.sync(canvas.groups, viewport: viewport, scale: 1)
                    if i >= 60 { total += tiles.rasterizedPixelsLastFrame } // skip warm-up
                }
                let perFrame = total / frames
                print("seasonal raster cost: \(perFrame) px/frame")
                // A screen is 3.7M px; the per-element tiles should be tiny.
                #expect(perFrame < 250_000, "rasterized \(perFrame) px/frame")
            }
        }
    }
}
