import Foundation

// String helpers that keep Rust-port semantics (ex-memory.rs).

nonisolated extension String {
    /// Rust `str::trim` (Unicode White_Space, both ends).
    func rustTrimmed() -> String {
        var scalars = Substring(self).unicodeScalars
        while let f = scalars.first, f.properties.isWhitespace { scalars.removeFirst() }
        while let l = scalars.last, l.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    /// Rust byte-wise (UTF-8) string ordering.
    func utf8Precedes(_ other: String) -> Bool {
        utf8.lexicographicallyPrecedes(other.utf8)
    }
}

/// Rust `Path::file_stem` for a bare file name: everything before the final
/// '.', or the whole name when there is no dot or it only starts with one.
nonisolated func rustFileStem(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return String(name[..<dot])
}
