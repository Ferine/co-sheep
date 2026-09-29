import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

// weather.rs had no Rust tests; these pin the URL, parsing, simplification and
// the cache rules, with a scripted fetch instead of the network.

private nonisolated final class FetchScript: Sendable {
    private let outcomes: Mutex<[Result<WeatherInfo, PlatformError>]>
    private let locations = Mutex<[String]>([])
    init(_ outcomes: [Result<WeatherInfo, PlatformError>]) { self.outcomes = Mutex(outcomes) }
    var calls: [String] { locations.withLock { $0 } }
    func next(_ location: String) throws -> WeatherInfo {
        locations.withLock { $0.append(location) }
        let outcome = outcomes.withLock { o in o.count > 1 ? o.removeFirst() : o[0] }
        return try outcome.get()
    }
}

private func info(_ condition: String = "Sunny", temp: Double? = 21) -> WeatherInfo {
    WeatherInfo(condition: condition, description: "\(condition), 21C (feels like 20C), 40% humidity", tempC: temp)
}

private let sampleJSON = #"""
{"current_condition":[{"FeelsLikeC":"9","FeelsLikeF":"48","cloudcover":"75","humidity":"81",
"observation_time":"03:00 PM","precipMM":"0.0","pressure":"1012","temp_C":"11","temp_F":"52",
"uvIndex":"1","visibility":"10","weatherCode":"116","weatherDesc":[{"value":"Partly cloudy"}],
"winddir16Point":"SW","windspeedKmph":"14"}],"nearest_area":[{"areaName":[{"value":"Oslo"}]}],"weather":[]}
"""#

@Suite("weather")
struct WeatherTests {
    // MARK: URL

    @Test func plainLocationURL() {
        #expect(Weather.wttrURL(location: "Oslo") == "https://wttr.in/Oslo?format=j1")
    }

    @Test func spacesBecomePlus() {
        #expect(Weather.wttrURL(location: "New York") == "https://wttr.in/New+York?format=j1")
        #expect(Weather.wttrURL(location: "Paris, France") == "https://wttr.in/Paris,+France?format=j1")
    }

    @Test func nonASCIIIsPercentEncodedPerUTF8Byte() {
        #expect(Weather.wttrURL(location: "Tromsø") == "https://wttr.in/Troms%C3%B8?format=j1")
        #expect(Weather.wttrURL(location: "東京") == "https://wttr.in/%E6%9D%B1%E4%BA%AC?format=j1")
    }

    @Test func urlSpecialCharactersCannotCorruptTheQuery() {
        #expect(Weather.wttrURL(location: "a/b?c#d%e") == "https://wttr.in/a%2Fb%3Fc%23d%25e?format=j1")
        #expect(Weather.wttrURL(location: "x&y=z") == "https://wttr.in/x%26y%3Dz?format=j1")
    }

    @Test func unreservedPunctuationPassesThrough() {
        #expect(Weather.wttrURL(location: "a-b_c.d~e,f") == "https://wttr.in/a-b_c.d~e,f?format=j1")
    }

    @Test func everyURLIsAValidURL() {
        for loc in ["Oslo", "New York", "Tromsø", "a/b?c#d%e", "  ", "😀", "a\nb", "100%"] {
            #expect(URL(string: Weather.wttrURL(location: loc)) != nil, "\(loc.debugDescription)")
        }
    }

    // MARK: parsing

    @Test func parsesWttrJSON() throws {
        let w = try Weather.parseWttr(Data(sampleJSON.utf8))
        #expect(w.condition == "Partly cloudy")
        #expect(w.description == "Partly cloudy, 11C (feels like 9C), 81% humidity")
        #expect(w.tempC == 11)
    }

    @Test func nonNumericTemperatureIsNil() throws {
        let json = sampleJSON.replacingOccurrences(of: #""temp_C":"11""#, with: #""temp_C":"n/a""#)
        let w = try Weather.parseWttr(Data(json.utf8))
        #expect(w.tempC == nil)
        #expect(w.description == "Partly cloudy, n/aC (feels like 9C), 81% humidity")
    }

    @Test func negativeAndFractionalTemperatures() throws {
        let json = sampleJSON.replacingOccurrences(of: #""temp_C":"11""#, with: #""temp_C":"-3""#)
        #expect(try Weather.parseWttr(Data(json.utf8)).tempC == -3)
    }

    @Test func emptyWeatherDescGivesAnEmptyCondition() throws {
        let json = sampleJSON.replacingOccurrences(of: #"[{"value":"Partly cloudy"}]"#, with: "[]")
        let w = try Weather.parseWttr(Data(json.utf8))
        #expect(w.condition == "")
        #expect(w.description == ", 11C (feels like 9C), 81% humidity")
    }

    @Test func emptyCurrentConditionFails() {
        #expect(throws: PlatformError("No current_condition in response")) {
            try Weather.parseWttr(Data(#"{"current_condition":[]}"#.utf8))
        }
    }

    @Test func missingRequiredFieldsFail() {
        // serde required all of these, including the unused weatherCode.
        for key in ["temp_C", "FeelsLikeC", "humidity", "weatherDesc", "weatherCode"] {
            let json = #"{"current_condition":[{"temp_C":"1","FeelsLikeC":"1","humidity":"1","weatherCode":"1","weatherDesc":[]}]}"#
            var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            var cond = (object["current_condition"] as! [[String: Any]])[0]
            cond[key] = nil
            object["current_condition"] = [cond]
            let data = try! JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self, "missing \(key)") { try Weather.parseWttr(data) }
        }
        #expect(throws: (any Error).self) { try Weather.parseWttr(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try Weather.parseWttr(Data("not json".utf8)) }
    }

    // MARK: simplification

    @Test(arguments: [
        ("Light rain", "rain"), ("Patchy light drizzle", "rain"), ("Light rain shower", "rain"),
        ("Torrential rain shower", "rain"), ("LIGHT RAIN", "rain"), ("Patchy rain possible", "rain"),
        ("Moderate snow", "snow"), ("Blowing snow", "snow"), ("Blizzard", "snow"),
        ("Light sleet", "snow"), ("Ice pellets", "snow"),
        ("Fog", "fog"), ("Freezing fog", "fog"), ("Mist", "fog"), ("Haze", "fog"),
        ("Partly cloudy", "cloudy"), ("Cloudy", "cloudy"), ("Overcast", "cloudy"),
        ("Sunny", "clear"), ("Clear", "clear"), ("Thundery outbreaks possible", "clear"), ("", "clear"),
        // The branches are tested in order, so "shower" wins over "snow"/"ice" (ported as-is).
        ("Moderate or heavy snow showers", "rain"),
        ("Moderate or heavy showers of ice pellets", "rain"),
        ("Light sleet showers", "rain"),
    ] as [(String, String)])
    func simplifiesConditions(desc: String, expected: String) {
        #expect(Weather.simplifyCondition(desc) == expected)
    }

    // MARK: caching and refresh rules

    private final class Clock { var ms = 0.0 }
    private final class LocationBox { var value = "Oslo" }

    private func makeWeather(
        location: String = "Oslo", script: FetchScript, clock: Clock = Clock()
    ) -> Weather {
        Weather(location: { location }, fetch: { try script.next($0) }, now: { clock.ms })
    }

    @Test func noLocationMeansNoWeatherAndNoFetch() async {
        let script = FetchScript([.success(info())])
        let weather = makeWeather(location: "", script: script)
        #expect(await weather.getWeather() == nil)
        #expect(await weather.getWeatherContext() == "")
        #expect(await weather.getWeatherSnapshot() == nil)
        #expect(script.calls.isEmpty)
    }

    @Test func aFreshFetchIsCachedForThirtyMinutes() async {
        let script = FetchScript([.success(info("Sunny")), .success(info("Rain"))])
        let clock = Clock()
        let weather = makeWeather(script: script, clock: clock)

        #expect(await weather.getWeather()?.condition == "Sunny")
        clock.ms = 29 * 60 * 1000 + 59_000
        #expect(await weather.getWeather()?.condition == "Sunny") // still cached
        #expect(script.calls == ["Oslo"])

        clock.ms = 30 * 60 * 1000 // elapsed == TTL is no longer "< TTL"
        #expect(await weather.getWeather()?.condition == "Rain")
        #expect(script.calls.count == 2)
    }

    @Test func aFailedRefreshReturnsTheStaleCache() async {
        let script = FetchScript([.success(info("Sunny")), .failure(PlatformError("offline"))])
        let clock = Clock()
        let weather = makeWeather(script: script, clock: clock)
        _ = await weather.getWeather()

        clock.ms = 45 * 60 * 1000
        #expect(await weather.getWeather()?.condition == "Sunny") // stale, but better than nothing

        // The failure did not refresh the timestamp, so every call retries.
        clock.ms = 46 * 60 * 1000
        _ = await weather.getWeather()
        #expect(script.calls.count == 3)
    }

    @Test func aFailureWithNothingCachedIsNil() async {
        let script = FetchScript([.failure(PlatformError("offline"))])
        let weather = makeWeather(script: script)
        #expect(await weather.getWeather() == nil)
        #expect(await weather.getWeather() == nil)
        #expect(script.calls.count == 2)
    }

    @Test func recoveryAfterAFailureCachesAgain() async {
        let script = FetchScript([.failure(PlatformError("offline")), .success(info("Fog"))])
        let clock = Clock()
        let weather = makeWeather(script: script, clock: clock)
        #expect(await weather.getWeather() == nil)
        #expect(await weather.getWeather()?.condition == "Fog")
        clock.ms = 60_000
        #expect(await weather.getWeather()?.condition == "Fog")
        #expect(script.calls.count == 2)
    }

    @Test func theLocationIsReadOnEveryCallButTheCacheIgnoresIt() async {
        // Ported as-is: the cache is not keyed by location, so a changed
        // location keeps serving the old place's weather until the TTL passes.
        let script = FetchScript([.success(info("Sunny")), .success(info("Snow"))])
        let clock = Clock()
        let location = LocationBox()
        let weather = Weather(location: { location.value }, fetch: { try script.next($0) }, now: { clock.ms })

        _ = await weather.getWeather()
        location.value = "Bergen"
        #expect(await weather.getWeather()?.condition == "Sunny")
        #expect(script.calls == ["Oslo"])

        clock.ms = 31 * 60 * 1000
        #expect(await weather.getWeather()?.condition == "Snow")
        #expect(script.calls == ["Oslo", "Bergen"])
    }

    @Test func contextAndSnapshot() async {
        let script = FetchScript([.success(WeatherInfo(
            condition: "Light rain", description: "Light rain, 8C (feels like 5C), 90% humidity", tempC: 8))])
        let weather = makeWeather(script: script)
        #expect(await weather.getWeatherContext() == "WEATHER: Light rain, 8C (feels like 5C), 90% humidity outside.")
        #expect(await weather.getWeatherSnapshot() == WeatherSnapshot(condition: "rain", tempC: 8))
    }

    @Test func snapshotWithoutATemperature() async {
        let script = FetchScript([.success(info("Overcast", temp: nil))])
        let snapshot = await makeWeather(script: script).getWeatherSnapshot()
        #expect(snapshot == WeatherSnapshot(condition: "cloudy", tempC: nil))
    }

    @Test func snapshotJSONKeepsTheSerdeShape() throws {
        let some = try JSONEncoder().encode(WeatherSnapshot(condition: "rain", tempC: 8.5))
        #expect(try JSONDecoder().decode(JSONValue.self, from: some)
            == .object(["condition": .string("rain"), "temp_c": .number(8.5)]))
        // serde writes None as null: the key is present.
        let none = try JSONEncoder().encode(WeatherSnapshot(condition: "clear", tempC: nil))
        #expect(try JSONDecoder().decode(JSONValue.self, from: none)
            == .object(["condition": .string("clear"), "temp_c": .null]))
        let back = try JSONDecoder().decode(WeatherSnapshot.self, from: Data(#"{"condition":"snow","temp_c":-2}"#.utf8))
        #expect(back == WeatherSnapshot(condition: "snow", tempC: -2))
        let noTemp = try JSONDecoder().decode(WeatherSnapshot.self, from: Data(#"{"condition":"fog"}"#.utf8))
        #expect(noTemp == WeatherSnapshot(condition: "fog", tempC: nil))
    }

    @Test func cacheTTLIsThirtyMinutes() {
        #expect(Weather.cacheTTLSeconds == 1800)
    }
}

// MARK: - The real request, against a stubbed URLProtocol

private nonisolated final class StubWttr: URLProtocol {
    struct Stub: Sendable {
        var status = 200
        var body = Data()
    }
    static let stub = Mutex(Stub())
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let stub = Self.stub.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("weather request", .serialized)
struct WeatherRequestTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWttr.self]
        return URLSession(configuration: config)
    }

    private func reset(status: Int = 200, body: String = sampleJSON) {
        StubWttr.stub.withLock { $0 = StubWttr.Stub(status: status, body: Data(body.utf8)) }
        StubWttr.requests.withLock { $0 = [] }
    }

    @Test func requestsWttrWithTheSameURLHeadersAndTimeout() async throws {
        reset()
        let w = try await Weather.fetchWeather(location: "New York", session: session())
        #expect(w.condition == "Partly cloudy")
        #expect(w.tempC == 11)

        let requests = StubWttr.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://wttr.in/New+York?format=j1")
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "co-sheep/0.1")
        #expect(requests[0].timeoutInterval == 10)
        #expect(requests[0].httpMethod == "GET")
    }

    @Test func nonSuccessStatusFails() async {
        reset(status: 503, body: "busy")
        await #expect(throws: PlatformError("Weather API returned 503")) {
            _ = try await Weather.fetchWeather(location: "Oslo", session: self.session())
        }
    }

    @Test func garbageBodyFails() async {
        reset(body: "<html>nope</html>")
        await #expect(throws: (any Error).self) {
            _ = try await Weather.fetchWeather(location: "Oslo", session: self.session())
        }
    }

    @Test func the2xxRangeIsSuccess() async throws {
        reset(status: 203)
        let w = try await Weather.fetchWeather(location: "Oslo", session: session())
        #expect(w.condition == "Partly cloudy")
    }

    @Test func defaultSessionEnforcesATenSecondTotalTimeout() {
        #expect(Weather.session.configuration.timeoutIntervalForResource == 10)
        #expect(Weather.session.configuration.timeoutIntervalForRequest == 10)
    }
}
