import Foundation
import Testing
@testable import CoSheepKit

@Suite("http request parsing")
struct HTTPParserTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func parsedRequest(_ raw: String) throws -> HTTPRequest {
        guard case .request(let r) = HTTPParser.parse(bytes(raw)) else {
            throw Failure("expected a complete request for: \(raw.debugDescription)")
        }
        return r
    }

    private struct Failure: Error { var message: String; init(_ m: String) { message = m } }

    @Test func parsesRequestLineHeadersAndBody() throws {
        let body = #"{"jsonrpc":"2.0"}"#
        let r = try parsedRequest(
            "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:4917\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(r.method == "POST")
        #expect(r.target == "/mcp?x=1")
        #expect(r.path == "/mcp")
        #expect(r.header("host") == "127.0.0.1:4917")
        #expect(String(decoding: r.body, as: UTF8.self) == body)
    }

    @Test func headerLookupIsCaseInsensitiveAndFirstWins() throws {
        let r = try parsedRequest("GET / HTTP/1.1\r\nAUTHORIZATION: Bearer a\r\nauthorization: Bearer b\r\n\r\n")
        #expect(r.header("Authorization") == "Bearer a")
        #expect(r.header("authorization") == "Bearer a")
        #expect(r.header("missing") == nil)
    }

    @Test func headerValuesAreTrimmedAndMayContainColons() throws {
        let r = try parsedRequest("GET / HTTP/1.1\r\nHost:   localhost:4917 \t\r\n\r\n")
        #expect(r.header("host") == "localhost:4917")
    }

    @Test func requestWithoutBodyHasEmptyBody() throws {
        let r = try parsedRequest("GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(r.body.isEmpty)
    }

    @Test func http10IsAccepted() throws {
        let r = try parsedRequest("GET /mcp HTTP/1.0\r\n\r\n")
        #expect(r.method == "GET")
    }

    @Test func waitsForCompleteHeaders() {
        #expect(HTTPParser.parse(bytes("POST /mcp HTTP/1.1\r\nHost: localhost\r\n")) == .needMore(expectContinue: false))
        #expect(HTTPParser.parse(Data()) == .needMore(expectContinue: false))
    }

    @Test func waitsForTheWholeBodyThenCompletes() throws {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        #expect(HTTPParser.parse(bytes(head + "01234")) == .needMore(expectContinue: false))
        let r = try parsedRequest(head + "0123456789")
        #expect(String(decoding: r.body, as: UTF8.self) == "0123456789")
    }

    @Test func incrementalFeedingMatchesOneShotParse() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"
        let whole = try parsedRequest(raw)
        var buffer = Data()
        var result: HTTPParser.Result?
        for byte in raw.utf8 {
            buffer.append(byte)
            result = HTTPParser.parse(buffer)
            if case .request = result { break }
        }
        #expect(result == .request(whole))
    }

    @Test func bytesBeyondContentLengthAreIgnored() throws {
        let r = try parsedRequest("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\nabEXTRA")
        #expect(String(decoding: r.body, as: UTF8.self) == "ab")
    }

    @Test func expectContinueIsFlaggedUntilTheBodyArrives() {
        let head = "POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n"
        #expect(HTTPParser.parse(bytes(head)) == .needMore(expectContinue: true))
        if case .request(let r) = HTTPParser.parse(bytes(head + "body")) {
            #expect(String(decoding: r.body, as: UTF8.self) == "body")
        } else {
            Issue.record("expected a request once the body arrived")
        }
    }

    @Test(arguments: [
        "GARBAGE\r\n\r\n",
        "GET /only-two-parts\r\n\r\n",
        "get /lowercase HTTP/1.1\r\n\r\n",
        "GET  / HTTP/1.1\r\n\r\n",
        "GET / FTP/1.1\r\n\r\n",
    ])
    func malformedRequestLineIs400(raw: String) {
        #expect(HTTPParser.parse(bytes(raw)) == .failure(status: 400, reason: "Bad Request: malformed request line"))
    }

    @Test func unsupportedHTTPVersionIs505() {
        guard case .failure(let status, _) = HTTPParser.parse(bytes("GET / HTTP/2.0\r\n\r\n")) else {
            Issue.record("expected failure")
            return
        }
        #expect(status == 505)
    }

    @Test func malformedHeaderIs400() {
        for raw in ["GET / HTTP/1.1\r\nno-colon-here\r\n\r\n",
                    "GET / HTTP/1.1\r\n: empty-name\r\n\r\n",
                    "GET / HTTP/1.1\r\nBad Name: x\r\n\r\n",
                    "GET / HTTP/1.1\r\nHost: a\r\n folded: x\r\n\r\n"] {
            guard case .failure(let status, _) = HTTPParser.parse(bytes(raw)) else {
                Issue.record("expected failure for \(raw.debugDescription)")
                continue
            }
            #expect(status == 400)
        }
    }

    @Test func invalidOrConflictingContentLengthIs400() {
        for raw in ["POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: \r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"] {
            guard case .failure(let status, _) = HTTPParser.parse(bytes(raw)) else {
                Issue.record("expected failure for \(raw.debugDescription)")
                continue
            }
            #expect(status == 400)
        }
    }

    @Test func duplicateIdenticalContentLengthIsFine() throws {
        let r = try parsedRequest("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nab")
        #expect(r.body.count == 2)
    }

    @Test func oversizedBodyIs413BeforeAnyBodyIsRead() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n"
        #expect(HTTPParser.parse(bytes(raw)) == .failure(status: 413, reason: "Content Too Large"))
        let huge = "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n"
        #expect(HTTPParser.parse(bytes(huge)) == .failure(status: 413, reason: "Content Too Large"))
    }

    @Test func bodyAtTheLimitIsAccepted() {
        let head = "POST / HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBodyBytes)\r\n\r\n"
        #expect(HTTPParser.parse(bytes(head)) == .needMore(expectContinue: false))
    }

    @Test func chunkedRequestsAreRejected() {
        let raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        guard case .failure(let status, _) = HTTPParser.parse(bytes(raw)) else {
            Issue.record("expected failure")
            return
        }
        #expect(status == 501)
    }

    @Test func endlessHeadersAre431() {
        let raw = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes + 10)
        guard case .failure(let status, _) = HTTPParser.parse(bytes(raw)) else {
            Issue.record("expected failure")
            return
        }
        #expect(status == 431)
    }

    // MARK: - Responses

    @Test func responseSerializationAddsContentLengthAndClose() {
        let response = HTTPResponse.json(200, Data(#"{"a":1}"#.utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n"
            + "Connection: close\r\n\r\n{\"a\":1}")
    }

    @Test func emptyResponseHasZeroContentLength() {
        let text = String(decoding: HTTPResponse(status: 202).serialized(), as: UTF8.self)
        #expect(text == "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    @Test func serializationOverridesUserSuppliedFraming() {
        let response = HTTPResponse(
            status: 405,
            headers: [HTTPHeader(name: "Allow", value: "POST"),
                      HTTPHeader(name: "content-length", value: "999"),
                      HTTPHeader(name: "Connection", value: "keep-alive")],
            body: Data("no".utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text.contains("Allow: POST\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(!text.contains("999"))
        #expect(!text.contains("keep-alive"))
        #expect(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    }

    @Test func contentLengthCountsBytesNotCharacters() {
        let response = HTTPResponse.text(200, "æøå")
        #expect(response.serialized().count > "æøå".count)
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text.contains("Content-Length: 6\r\n"))
    }
}
