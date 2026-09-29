import CoreText
import Foundation

/// Parsed CSS `font` shorthand for Canvas: `[italic] [bold|<weight>] <size>px <family>[, fallback…]`.
struct CSSFont: Equatable, Hashable {
    var size: Double
    var bold: Bool
    var italic: Bool
    var family: String   // resolved PostScript/family name

    static let `default` = CSSFont(size: 10, bold: false, italic: false, family: "Helvetica")

    private static var cache: [String: CSSFont] = [:]
    private static var ctCache: [CSSFont: CTFont] = [:]

    /// nil for strings Canvas would reject (the assignment is then ignored).
    static func parse(_ input: String) -> CSSFont? {
        if let hit = cache[input] { return hit }
        guard let f = parseUncached(input) else { return nil }
        cache[input] = f
        return f
    }

    private static func parseUncached(_ input: String) -> CSSFont? {
        var tokens = input.trimmingCharacters(in: .whitespaces)[...]
        var bold = false
        var italic = false
        var size: Double?
        // Consume style/weight keywords, then the size token.
        while !tokens.isEmpty {
            let word = tokens.prefix { $0 != " " }
            let lw = word.lowercased()
            if lw == "italic" || lw == "oblique" { italic = true }
            else if lw == "bold" || lw == "bolder" { bold = true }
            else if let w = Int(lw), w >= 100, w <= 1000, !lw.hasSuffix("px") { bold = w >= 600 }
            else if lw == "normal" || lw == "lighter" || lw == "small-caps" {}
            else if lw.hasSuffix("px"), let v = Double(lw.dropLast(2)) {
                size = v
                tokens = tokens.dropFirst(word.count)
                break
            } else { return nil }
            tokens = tokens.dropFirst(word.count).drop { $0 == " " }
        }
        guard let size else { return nil }
        // Optional "/line-height" right after the size.
        var rest = tokens.drop { $0 == " " }
        if rest.hasPrefix("/") { rest = rest.drop { $0 != " " }.drop { $0 == " " } }
        let families = rest.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        guard let first = families.first, !first.isEmpty else { return nil }
        return CSSFont(size: size, bold: bold, italic: italic, family: resolveFamily(families))
    }

    /// WebKit-on-macOS generic defaults: monospace → Courier, serif → Times,
    /// sans-serif → Helvetica.
    private static func resolveFamily(_ families: [String]) -> String {
        for fam in families {
            switch fam.lowercased() {
            case "monospace": return "Courier"
            case "serif": return "Times"
            case "sans-serif", "system-ui", "-apple-system": return "Helvetica"
            default:
                let probe = CTFontCreateWithName(fam as CFString, 12, nil)
                let got = CTFontCopyFamilyName(probe) as String
                if got.caseInsensitiveCompare(fam) == .orderedSame { return fam }
            }
        }
        return "Helvetica"
    }

    var ctFont: CTFont {
        if let hit = CSSFont.ctCache[self] { return hit }
        var font = CTFontCreateWithName(family as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) {
            font = styled
        }
        CSSFont.ctCache[self] = font
        return font
    }
}

/// CTLine cache for measure + draw (same string/font every frame is the norm).
enum TextLines {
    private struct Key: Hashable { var text: String; var font: CSSFont }
    private static var cache: [Key: CTLine] = [:]

    static func line(_ text: String, _ font: CSSFont) -> CTLine {
        let key = Key(text: text, font: font)
        if let hit = cache[key] { return hit }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font.ctFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }
        cache[key] = line
        return line
    }

    static func width(_ text: String, _ font: CSSFont) -> Double {
        Double(CTLineGetTypographicBounds(line(text, font), nil, nil, nil))
    }
}
