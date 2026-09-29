import Foundation
import Network
import Synchronization

// A minimal HTTP/1.1 server on Network.framework, just enough for the MCP
// endpoint (ex-axum). One request per connection: the request line, headers and
// a Content-Length body are parsed, and every response carries Content-Length
// and `Connection: close`. All socket work happens off the main actor.

nonisolated struct HTTPHeader: Equatable {
    var name: String
    var value: String
}

nonisolated struct HTTPRequest: Equatable {
    var method: String
    /// Request target exactly as sent (path plus optional query).
    var target: String
    var headers: [HTTPHeader]
    var body: Data

    init(method: String, target: String, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// The target without its query string.
    var path: String {
        if let q = target.firstIndex(of: "?") { return String(target[..<q]) }
        return target
    }

    /// First header with this name (case-insensitive), like hyper's `headers().get`.
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
    }
}

nonisolated struct HTTPResponse: Equatable {
    var status: Int
    var headers: [HTTPHeader] = []
    var body = Data()

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")],
            body: Data(message.utf8))
    }

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
            body: body)
    }

    /// Status line, headers (plus Content-Length and `Connection: close`), body.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for h in headers {
            let n = h.name.lowercased()
            if n == "content-length" || n == "connection" { continue }
            head += "\(h.name): \(h.value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 505: "HTTP Version Not Supported"
        default: "Status \(status)"
        }
    }
}

/// Incremental parser: feed it everything received so far.
nonisolated enum HTTPParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum Result: Equatable {
        /// Not enough bytes yet. `expectContinue` is true once the headers are
        /// complete, carry `Expect: 100-continue` and the body is still missing.
        case needMore(expectContinue: Bool)
        case request(HTTPRequest)
        /// Malformed or unsupported; answer with this status and close.
        case failure(status: Int, reason: String)
    }

    static func parse(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        guard let headEnd = indexOfHeaderEnd(bytes) else {
            if bytes.count > maxHeaderBytes {
                return .failure(status: 431, reason: "Request header too large")
            }
            return .needMore(expectContinue: false)
        }
        if headEnd > maxHeaderBytes {
            return .failure(status: 431, reason: "Request header too large")
        }

        let lines = splitLines(Array(bytes[..<headEnd]))
        guard let requestLine = lines.first else {
            return .failure(status: 400, reason: "Bad Request: empty request")
        }

        // Request line: METHOD SP target SP HTTP/1.x
        let parts = string(requestLine).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && $0.isUppercase })
        else { return .failure(status: 400, reason: "Bad Request: malformed request line") }
        let version = parts[2]
        guard version.hasPrefix("HTTP/1.") else {
            return version.hasPrefix("HTTP/")
                ? .failure(status: 505, reason: "HTTP Version Not Supported")
                : .failure(status: 400, reason: "Bad Request: malformed request line")
        }

        // Headers: name ":" OWS value OWS
        var headers: [HTTPHeader] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > 0 else {
                return .failure(status: 400, reason: "Bad Request: malformed header")
            }
            let name = string(Array(line[..<colon]))
            if name.contains(where: { $0 == " " || $0 == "\t" }) {
                return .failure(status: 400, reason: "Bad Request: malformed header")
            }
            let value = string(Array(line[(colon + 1)...])).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append(HTTPHeader(name: name, value: value))
        }
        var request = HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers)

        // Only Content-Length bodies are supported.
        if request.header("transfer-encoding") != nil {
            return .failure(status: 501, reason: "Transfer-Encoding is not supported; send Content-Length")
        }
        let lengths = headers.filter { $0.name.lowercased() == "content-length" }.map(\.value)
        var contentLength = 0
        if let first = lengths.first {
            guard lengths.allSatisfy({ $0 == first }), !first.isEmpty, first.allSatisfy(\.isASCIIDigit) else {
                return .failure(status: 400, reason: "Bad Request: invalid Content-Length")
            }
            guard first.count <= 9, let n = Int(first) else {
                return .failure(status: 413, reason: "Content Too Large")
            }
            if n > maxBodyBytes { return .failure(status: 413, reason: "Content Too Large") }
            contentLength = n
        }

        let bodyStart = headEnd + 4
        let available = bytes.count - bodyStart
        if available < contentLength {
            let expect = request.header("expect")?.lowercased() == "100-continue"
            return .needMore(expectContinue: expect)
        }
        request.body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
        return .request(request)
    }

    /// Index of the first CRLF CRLF (the end of the header block), if present.
    private static func indexOfHeaderEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4)
        where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i
        }
        return nil
    }

    private static func splitLines(_ b: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        var i = 0
        while i < b.count {
            if b[i] == 13, i + 1 < b.count, b[i + 1] == 10 {
                lines.append(Array(b[start..<i]))
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        lines.append(Array(b[start...]))
        return lines
    }

    private static func string(_ b: [UInt8]) -> String {
        String(decoding: b, as: UTF8.self)
    }
}

private nonisolated extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

/// Loopback-only HTTP/1.1 listener. `handler` runs off the main actor, once per
/// request; hop to the main actor inside it only for main-actor state.
nonisolated final class HTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// A client has this long to deliver a complete request.
    static let readTimeout: Duration = .seconds(30)

    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    private let queue = DispatchQueue(label: "co-sheep.http-server")
    private let handler: Handler
    private let state = Mutex(State())

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Binds 127.0.0.1:`port` (0 picks a free port) and returns the bound port
    /// once the listener is ready. Throws if the port is unavailable.
    func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [self] connection in
            accept(connection)
        }

        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.start(queue: queue)

        var bound: UInt16?
        var failure: Error?
        wait: for await s in states {
            switch s {
            case .ready:
                bound = listener.port?.rawValue ?? port
                break wait
            case .failed(let error), .waiting(let error):
                failure = error
                break wait
            case .cancelled:
                failure = PlatformError("listener cancelled")
                break wait
            default:
                continue
            }
        }
        continuation.finish()

        guard let bound else {
            listener.cancel()
            throw failure ?? CancellationError()
        }
        listener.stateUpdateHandler = { newState in
            if case .failed(let error) = newState {
                Log.info("mcp", "error: listener failed: \(error)")
            }
        }
        state.withLock { $0.listener = listener }
        return bound
    }

    /// Stops listening and drops open connections.
    func stop() {
        let (listener, connections) = state.withLock { s in
            let taken = (s.listener, Array(s.connections.values))
            s.listener = nil
            s.connections = [:]
            return taken
        }
        listener?.cancel()
        for c in connections { c.cancel() }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        state.withLock { $0.connections[id] = connection }
        Task {
            await serve(connection)
            state.withLock { $0.connections[id] = nil }
        }
    }

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: queue)
        let watchdog = Task {
            try await Task.sleep(for: Self.readTimeout)
            connection.cancel()
        }
        defer {
            watchdog.cancel()
            connection.cancel()
        }

        var buffer = Data()
        var sentContinue = false
        do {
            var response: HTTPResponse?
            while response == nil {
                switch HTTPParser.parse(buffer) {
                case .request(let request):
                    watchdog.cancel()
                    response = await handler(request)
                case .failure(let status, let reason):
                    response = .text(status, reason)
                case .needMore(let expectContinue):
                    if expectContinue, !sentContinue {
                        sentContinue = true
                        try await Self.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
                    }
                    guard let chunk = try await Self.receive(on: connection) else { return }
                    buffer.append(chunk)
                }
            }
            if let response {
                try await Self.send(response.serialized(), on: connection)
            }
        } catch {
            Log.debug("mcp", "connection error: \(error)")
        }
    }

    /// Next chunk from the peer, or nil once it closed the connection.
    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
