import CoreGraphics
import Foundation

/// Straight (non-premultiplied) sRGB color, components 0…1.
nonisolated struct RGBA: Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}

/// CSS color string parsing for the Canvas API: #rgb #rgba #rrggbb #rrggbbaa,
/// rgb()/rgba() (comma or space syntax, % channels, `/ alpha`), hsl()/hsla(),
/// and CSS named colors. Results are cached by the exact input string.
enum CSSColor {
    private static var cache: [String: RGBA?] = [:]

    static func parse(_ input: String) -> RGBA? {
        if let hit = cache[input] { return hit }
        let result = parseUncached(input)
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[input] = result
        return result
    }

    private static func parseUncached(_ input: String) -> RGBA? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let fn = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            let body = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            let (parts, slashAlpha) = splitArgs(body)
            switch fn {
            case "rgb", "rgba": return parseRGB(parts, slashAlpha)
            case "hsl", "hsla": return parseHSL(parts, slashAlpha)
            default: return nil
            }
        }
        return named[s]
    }

    private static func parseHex(_ h: String) -> RGBA? {
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        func nib(_ i: Int) -> Double {
            let c = h[h.index(h.startIndex, offsetBy: i)]
            let v = Double(Int(String(c), radix: 16)!)
            return (v * 17) / 255
        }
        func byte(_ i: Int) -> Double {
            let start = h.index(h.startIndex, offsetBy: i)
            return Double(Int(h[start..<h.index(start, offsetBy: 2)], radix: 16)!) / 255
        }
        switch h.count {
        case 3: return RGBA(r: nib(0), g: nib(1), b: nib(2), a: 1)
        case 4: return RGBA(r: nib(0), g: nib(1), b: nib(2), a: nib(3))
        case 6: return RGBA(r: byte(0), g: byte(2), b: byte(4), a: 1)
        case 8: return RGBA(r: byte(0), g: byte(2), b: byte(4), a: byte(6))
        default: return nil
        }
    }

    /// Split "a, b, c" / "a b c / d" into channel parts + optional slash alpha.
    private static func splitArgs(_ body: String) -> ([String], String?) {
        var main = body
        var slash: String?
        if let i = body.firstIndex(of: "/") {
            main = String(body[..<i])
            slash = body[body.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let parts = main
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (parts, slash)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    private static func alpha(_ s: String?) -> Double? {
        guard let s else { return 1 }
        if s.hasSuffix("%") { return number(String(s.dropLast())).map { clamp01($0 / 100) } }
        return number(s).map(clamp01)
    }

    private static func parseRGB(_ p: [String], _ slash: String?) -> RGBA? {
        guard p.count == 3 || p.count == 4 else { return nil }
        func ch(_ s: String) -> Double? {
            if s.hasSuffix("%") { return number(String(s.dropLast())).map { clamp01($0 / 100) } }
            return number(s).map { clamp01($0 / 255) }
        }
        guard let r = ch(p[0]), let g = ch(p[1]), let b = ch(p[2]),
              let a = alpha(p.count == 4 ? p[3] : slash) else { return nil }
        return RGBA(r: r, g: g, b: b, a: a)
    }

    private static func parseHSL(_ p: [String], _ slash: String?) -> RGBA? {
        guard p.count == 3 || p.count == 4 else { return nil }
        let hs = p[0].replacingOccurrences(of: "deg", with: "")
        guard let hDeg = number(hs),
              let sPct = number(p[1].replacingOccurrences(of: "%", with: "")),
              let lPct = number(p[2].replacingOccurrences(of: "%", with: "")),
              let a = alpha(p.count == 4 ? p[3] : slash) else { return nil }
        let (r, g, b) = hslToRGB(h: hDeg, s: clamp01(sPct / 100), l: clamp01(lPct / 100))
        return RGBA(r: r, g: g, b: b, a: a)
    }

    nonisolated static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func t(_ x: Double) -> Double {
            var x = x
            if x < 0 { x += 1 }
            if x > 1 { x -= 1 }
            if x < 1.0 / 6 { return p + (q - p) * 6 * x }
            if x < 0.5 { return q }
            if x < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - x) * 6 }
            return p
        }
        return (t(hue + 1.0 / 3), t(hue), t(hue - 1.0 / 3))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    nonisolated private static func rgb(_ hex: UInt32) -> RGBA {
        RGBA(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
             b: Double(hex & 0xFF) / 255, a: 1)
    }

    private static let named: [String: RGBA] = {
        let table: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "lime": 0x00FF00,
            "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00, "cyan": 0x00FFFF,
            "aqua": 0x00FFFF, "magenta": 0xFF00FF, "fuchsia": 0xFF00FF, "gray": 0x808080,
            "grey": 0x808080, "silver": 0xC0C0C0, "maroon": 0x800000, "olive": 0x808000,
            "purple": 0x800080, "teal": 0x008080, "navy": 0x000080, "orange": 0xFFA500,
            "pink": 0xFFC0CB, "brown": 0xA52A2A, "gold": 0xFFD700, "hotpink": 0xFF69B4,
            "skyblue": 0x87CEEB, "lightblue": 0xADD8E6, "darkgreen": 0x006400,
            "lightgreen": 0x90EE90, "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9,
            "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "dimgray": 0x696969,
            "beige": 0xF5F5DC, "tan": 0xD2B48C, "khaki": 0xF0E68C, "coral": 0xFF7F50,
            "tomato": 0xFF6347, "salmon": 0xFA8072, "crimson": 0xDC143C, "violet": 0xEE82EE,
            "indigo": 0x4B0082, "turquoise": 0x40E0D0, "chocolate": 0xD2691E,
            "saddlebrown": 0x8B4513, "sienna": 0xA0522D, "ivory": 0xFFFFF0,
            "whitesmoke": 0xF5F5F5, "snow": 0xFFFAFA, "orangered": 0xFF4500,
            "goldenrod": 0xDAA520, "forestgreen": 0x228B22, "limegreen": 0x32CD32,
            "royalblue": 0x4169E1, "steelblue": 0x4682B4, "slategray": 0x708090,
            "darkred": 0x8B0000, "darkblue": 0x00008B, "deeppink": 0xFF1493,
            "lavender": 0xE6E6FA, "plum": 0xDDA0DD, "wheat": 0xF5DEB3,
        ]
        var out = table.mapValues(rgb)
        out["transparent"] = .transparent
        return out
    }()
}
