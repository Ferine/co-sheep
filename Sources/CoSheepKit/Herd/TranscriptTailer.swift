import Darwin
import Foundation

// Transcript tailing for the agent herd. Claude Code appends one JSON object per
// line to `transcript_path`. The format is undocumented, so everything here is
// defensive: unknown lines and malformed JSON are skipped, and only the few
// fields the herd needs are read (never prompts or tool I/O).
//
// Lines the herd cares about:
//   {"type":"assistant","message":{"id":"msg_…","usage":{input_tokens,
//     cache_creation_input_tokens,cache_read_input_tokens,output_tokens}}}
//       Several lines (one per content block) carry the same message.id and the
//       same usage, so the four numbers are added once per id.
//   {"type":"ai-title","aiTitle":"…"}                       the session title
//   {"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
//       the only trace of a human interrupt (no hook fires for it).

/// What a stretch of new transcript bytes added up to.
nonisolated struct TranscriptUpdate: Equatable, Sendable {
    /// Σ input + cache creation + cache read + output of messages not seen before.
    var tokensDelta: Int = 0
    /// The last `ai-title` in the new bytes.
    var title: String?
    /// The new bytes end with a human interrupt (no assistant reply or new
    /// prompt after it).
    var interrupted: Bool = false
    /// When the file last grew (its modification time). Stamped by the reader
    /// (the parser has no clock); nil from a bare `consume`.
    var grewAtMs: Double?

    /// Nothing the reducer could act on.
    var isEmpty: Bool { tokensDelta == 0 && title == nil && !interrupted }
}

/// Incremental parser state for one transcript: where we are in the file, the
/// unfinished last line, and the message ids already counted.
nonisolated struct TranscriptCursor: Equatable, Sendable {
    /// File offset of the next byte to read (bytes consumed so far, carry included).
    private(set) var offset: Int = 0
    /// Bytes after the last newline: a line still being written.
    private(set) var carry = Data()
    private(set) var seenMessageIds: Set<String> = []

    /// A line longer than this without a newline is garbage; drop it rather than
    /// grow without bound.
    static let maxCarryBytes = 64 * 1024 * 1024

    static let interruptMarker = "[Request interrupted by user"

    init() {}

    /// Start over at byte 0 (the file shrank or was replaced). Messages already
    /// counted stay counted: a rewritten file must not double-count tokens.
    mutating func rewind() {
        offset = 0
        carry = Data()
    }

    /// Feed the next bytes of the file (in order, no gaps).
    mutating func consume(_ data: Data) -> TranscriptUpdate {
        var update = TranscriptUpdate()
        guard !data.isEmpty else { return update }
        offset += data.count

        var buffer = carry
        carry = Data()
        buffer.append(data)

        var interrupted = false
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lineStart = 0
            let count = raw.count
            while lineStart < count {
                guard let nl = Self.indexOfNewline(raw, from: lineStart) else { break }
                if nl > lineStart {
                    handle(UnsafeRawBufferPointer(rebasing: raw[lineStart..<nl]), &update, &interrupted)
                }
                lineStart = nl + 1
            }
            if lineStart < count {
                let rest = UnsafeRawBufferPointer(rebasing: raw[lineStart..<count])
                // A complete JSON object can't be a prefix of a longer line, so a
                // final line that already parses is done even without its newline.
                if Self.endsLikeObject(rest), handle(rest, &update, &interrupted, unterminated: true) {
                    carry = Data()
                } else if rest.count <= Self.maxCarryBytes {
                    carry = Self.copy(rest)
                }
            }
        }
        update.interrupted = interrupted
        return update
    }

    // MARK: Lines

    private enum Kind {
        /// An assistant line. `tokens` is set only when it carries `usage`.
        case assistant(id: String?, tokens: Int?, endsInterrupt: Bool)
        case title(String)
        case prompt(isInterrupt: Bool)
        case other
    }

    /// Folds one line into `update`. Returns true when the line parsed as a JSON
    /// object. A final line without its newline (`unterminated`) is always
    /// parsed, since a byte prefilter on half a line proves nothing.
    @discardableResult
    private mutating func handle(
        _ line: UnsafeRawBufferPointer, _ update: inout TranscriptUpdate, _ interrupted: inout Bool,
        unterminated: Bool = false
    ) -> Bool {
        // Cheap byte prefilters: most lines (tool results, attachments, file
        // snapshots) are large and irrelevant, so only parse a line that could
        // matter. Once an interrupt is pending, any line may end it.
        let interesting = unterminated || interrupted
            || Self.contains(line, "\"usage\"")
            || Self.contains(line, "ai-title")
            || Self.contains(line, Self.interruptMarker)
        guard interesting else { return true }

        guard let object = try? JSONSerialization.jsonObject(with: Self.copy(line)) as? [String: Any] else {
            return false
        }
        switch Self.classify(object) {
        case .assistant(let id, let tokens, let endsInterrupt):
            if endsInterrupt { interrupted = false }
            guard let tokens else { break }
            if let id, !seenMessageIds.insert(id).inserted { break }
            update.tokensDelta += tokens
        case .title(let title):
            update.title = title
        case .prompt(let isInterrupt):
            interrupted = isInterrupt
        case .other:
            break
        }
        return true
    }

    private static func classify(_ object: [String: Any]) -> Kind {
        switch object["type"] as? String {
        case "assistant":
            let message = object["message"] as? [String: Any]
            // Claude Code's own placeholder replies ("No response requested.")
            // can follow an interrupt; they are not the agent answering.
            let endsInterrupt = message?["model"] as? String != "<synthetic>"
            guard let usage = message?["usage"] as? [String: Any] else {
                return .assistant(id: nil, tokens: nil, endsInterrupt: endsInterrupt)
            }
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + count(usage[$1]) }
            let id = (message?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .assistant(id: id, tokens: tokens, endsInterrupt: endsInterrupt)
        case "ai-title":
            guard let raw = object["aiTitle"] as? String else { return .other }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? .other : .title(SessionReducer.truncate(title, 200))
        case "user":
            guard let content = (object["message"] as? [String: Any])?["content"] else { return .other }
            if let text = content as? String {
                return .prompt(isInterrupt: isInterruptMarker(text))
            }
            guard let blocks = content as? [Any] else { return .other }
            var sawText = false
            for case let block as [String: Any] in blocks where block["type"] as? String == "text" {
                sawText = true
                if let text = block["text"] as? String, isInterruptMarker(text) {
                    return .prompt(isInterrupt: true)
                }
            }
            // A tool_result-only line is not a prompt: it can't end an interrupt.
            return sawText ? .prompt(isInterrupt: false) : .other
        default:
            return .other
        }
    }

    /// The marker is the whole text block ("[Request interrupted by user]",
    /// "[Request interrupted by user for tool use]"). Requiring it at the start
    /// keeps a prompt that merely quotes it from counting.
    private static func isInterruptMarker(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(interruptMarker)
    }

    /// A token count from a JSON number; anything else (missing, string, bool,
    /// negative) is 0.
    private static func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        return max(0, number.intValue)
    }

    // MARK: Bytes

    private static func indexOfNewline(_ raw: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = raw.baseAddress, from < raw.count else { return nil }
        guard let hit = memchr(base + from, 0x0A, raw.count - from) else { return nil }
        return base.distance(to: UnsafeRawPointer(hit))
    }

    private static func contains(_ raw: UnsafeRawBufferPointer, _ needle: String) -> Bool {
        guard let base = raw.baseAddress, !raw.isEmpty else { return false }
        return needle.withCString { ptr in
            memmem(base, raw.count, ptr, strlen(ptr)) != nil
        }
    }

    private static func copy(_ raw: UnsafeRawBufferPointer) -> Data {
        guard let base = raw.baseAddress, !raw.isEmpty else { return Data() }
        return Data(bytes: base, count: raw.count)
    }

    /// The last non-space byte is `}`.
    private static func endsLikeObject(_ raw: UnsafeRawBufferPointer) -> Bool {
        raw.last(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) == UInt8(ascii: "}")
    }
}

// MARK: - Reading the file

/// A poll's outcome: the advanced cursor and what it found (nil when the file
/// didn't grow, is missing, or isn't a transcript we'll read).
nonisolated struct TranscriptRead: Equatable, Sendable {
    var cursor: TranscriptCursor
    var update: TranscriptUpdate?
}

/// Reads new bytes of a transcript given its cursor. Injected into `HerdStore`.
typealias TranscriptReader = @Sendable (_ path: String, _ cursor: TranscriptCursor, _ nowMs: Double) async
    -> TranscriptRead

nonisolated enum TranscriptTailer {
    /// Most bytes taken from the file per read (the rest comes on the next poll).
    static let maxReadBytes = 50 * 1024 * 1024

    /// Whether a hook payload's `transcript_path` has the shape Claude Code
    /// gives transcripts, `…/projects/<project>/<session_id>.jsonl`. Anyone who
    /// can POST to `/hook` chooses that path, so the tailer is never pointed at
    /// arbitrary files.
    static func isTranscriptPath(_ raw: String, sessionId: String) -> Bool {
        guard !sessionId.isEmpty, raw.hasPrefix("/") || raw.hasPrefix("~/") else { return false }
        let parts = URL(fileURLWithPath: expand(raw)).pathComponents
        return parts.count >= 4
            && !parts.contains("..") && !parts.contains(".")
            && parts[parts.count - 1] == "\(sessionId).jsonl"
            && parts[parts.count - 3] == "projects"
    }

    /// `~` expansion, like the shell would do for a path from a hook payload.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// The production `TranscriptReader`: file I/O off the main actor.
    @concurrent
    static func read(path: String, cursor: TranscriptCursor, nowMs: Double) async -> TranscriptRead {
        readNew(path: path, cursor: cursor, nowMs: nowMs)
    }

    /// Blocking read of whatever was appended since `cursor`. A missing or
    /// unreadable file leaves the cursor alone; a file that shrank rewinds it to
    /// the start. Only absolute `.jsonl` regular files are read: the path comes
    /// from a hook payload, so it is not trusted to name a device or a FIFO.
    static func readNew(
        path: String, cursor: TranscriptCursor, nowMs: Double, maxBytes: Int = maxReadBytes
    ) -> TranscriptRead {
        let unchanged = TranscriptRead(cursor: cursor, update: nil)
        let expanded = expand(path)
        guard expanded.hasPrefix("/"), expanded.hasSuffix(".jsonl") else { return unchanged }

        // Open first, then check what was opened: a stat-then-open pair could be
        // raced into a FIFO (which would block) or a device. O_NONBLOCK keeps the
        // open itself from blocking; O_NOFOLLOW refuses a symlinked leaf.
        let fd = open(expanded, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return unchanged }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return unchanged }
        let size = Int(info.st_size)

        var cursor = cursor
        if size < cursor.offset { cursor.rewind() }
        guard size > cursor.offset else { return TranscriptRead(cursor: cursor, update: nil) }

        let data: Data
        do {
            try handle.seek(toOffset: UInt64(cursor.offset))
            data = try handle.read(upToCount: min(size - cursor.offset, maxBytes)) ?? Data()
        } catch {
            return unchanged
        }
        guard !data.isEmpty else { return TranscriptRead(cursor: cursor, update: nil) }

        // The file's own modification time, so replaying an old transcript at
        // startup doesn't pass for fresh activity; never later than now.
        let modifiedMs = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        var update = cursor.consume(data)
        update.grewAtMs = min(nowMs, modifiedMs)
        return TranscriptRead(cursor: cursor, update: update)
    }
}
