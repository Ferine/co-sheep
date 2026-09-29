import AppKit
import Foundation

/// Locates bundled resources (sprites, icons). In the assembled .app the
/// SwiftPM resource bundle is copied into Contents/Resources, where the
/// generated `Bundle.module` accessor does not look (it would trap), so we
/// check there first and only fall back to `Bundle.module` in dev/tests.
enum ResourceFiles {
    static let bundleName = "co-sheep_CoSheepKit.bundle"

    static let bundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ]
        for case let url? in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }()

    /// `path` relative to the Resources folder, e.g. "sprites/sheep-idle.png".
    static func url(_ path: String) -> URL? {
        // `.copy("Resources")` lands at <bundle>/Contents/Resources/Resources/.
        let bases = [bundle.resourceURL, bundle.bundleURL].compactMap { $0 }
        for base in bases {
            for u in [base.appendingPathComponent("Resources").appendingPathComponent(path),
                      base.appendingPathComponent(path)]
            where FileManager.default.fileExists(atPath: u.path) {
                return u
            }
        }
        return nil
    }

    static func cgImage(_ path: String) -> CGImage? {
        guard let url = url(path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func nsImage(_ path: String) -> NSImage? {
        url(path).flatMap { NSImage(contentsOf: $0) }
    }
}
