import Foundation

/// Timestamped, tagged dev logging (ex-logging.rs). `info` always prints;
/// `debug` only when CO_SHEEP_DEBUG=1|true. Both write to stderr in the
/// `HH:MM:SS [tag    ] msg` format.
nonisolated enum Log {
    static let isDebug: Bool = {
        let v = ProcessInfo.processInfo.environment["CO_SHEEP_DEBUG"]
        return v == "1" || v == "true"
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let lock = NSLock()

    static func line(_ tag: String, _ message: String, date: Date = Date()) -> String {
        let padded = tag.count >= 7 ? tag : tag + String(repeating: " ", count: 7 - tag.count)
        lock.lock()
        let stamp = formatter.string(from: date)
        lock.unlock()
        return "\(stamp) [\(padded)] \(message)"
    }

    static func info(_ tag: String, _ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data((line(tag, message()) + "\n").utf8))
    }

    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        guard isDebug else { return }
        info(tag, message())
    }

    /// Char-boundary-safe head truncation (by UTF-8 bytes) with an ellipsis —
    /// logs are full of æ/ø/å.
    static func truncateForLog(_ s: String, maxBytes: Int) -> String {
        let t = truncateUTF8(s, maxBytes: maxBytes)
        return t.utf8.count == s.utf8.count ? s : t + "…"
    }

    /// Raw model output for a log line: full at debug verbosity, else 200 bytes.
    static func rawForLog(_ s: String) -> String {
        isDebug ? s : truncateForLog(s, maxBytes: 200)
    }

    /// Strip one leading legacy "[co-sheep] " / "[co-sheep:id] " prefix.
    static func stripLegacyPrefix(_ message: String) -> String {
        guard message.hasPrefix("[co-sheep") else { return message }
        let rest = message.dropFirst("[co-sheep".count)
        guard let r = rest.range(of: "] ") else { return message }
        return String(rest[r.upperBound...])
    }
}

/// Truncate to at most `maxBytes` UTF-8 bytes without splitting a character.
nonisolated func truncateUTF8(_ s: String, maxBytes: Int) -> String {
    if s.utf8.count <= maxBytes { return s }
    var out = ""
    var used = 0
    for ch in s {
        let n = String(ch).utf8.count
        if used + n > maxBytes { break }
        out.append(ch)
        used += n
    }
    return out
}
