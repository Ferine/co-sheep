import Foundation

// Ex-weather.rs: wttr.in current conditions with a 30 minute cache.

nonisolated struct WeatherInfo: Equatable {
    var condition: String
    var description: String
    var tempC: Double?
}

/// Simplified condition plus temperature, for the overlay's weather effects
/// and the summer event trigger (ex-`WeatherSnapshot`, JSON keys unchanged).
nonisolated struct WeatherSnapshot: Equatable, Codable {
    var condition: String
    var tempC: Double?

    enum CodingKeys: String, CodingKey {
        case condition
        case tempC = "temp_c"
    }

    init(condition: String, tempC: Double?) {
        self.condition = condition
        self.tempC = tempC
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = try c.decode(String.self, forKey: .condition)
        tempC = try c.decodeIfPresent(Double.self, forKey: .tempC)
    }

    /// serde writes `None` as `null`, so the key is always present.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(condition, forKey: .condition)
        try c.encode(tempC, forKey: .tempC)
    }
}

/// Weather lookups. The location comes from config (Brain's module, written in
/// parallel), so it is a closure the app shell sets once:
/// `Weather.shared.location = { … }`.
final class Weather {
    static let shared = Weather()

    /// ex-`CACHE_TTL_SECS`: 30 minutes.
    static let cacheTTLSeconds = 30.0 * 60.0

    /// ex-`onboarding::get_weather_location()`. An empty string disables weather.
    var location: () -> String

    private let fetch: @Sendable (String) async throws -> WeatherInfo
    private let now: () -> Double

    // ex-`WeatherCache`, now keyed by location (Rust kept serving the old
    // place for up to 30 min after a Settings change) and with a failure
    // back-off (Rust re-fetched — up to a 10s wait — on every call while
    // wttr.in was down).
    private var cachedInfo: WeatherInfo?
    private var cachedAtMs: Double?
    private var cachedLocation: String?
    private var failedAtMs: Double?
    static let failureBackoffSeconds = 5.0 * 60.0

    /// - Parameters:
    ///   - fetch: the network call. Injected in tests.
    ///   - now: monotonic milliseconds (ex-`Instant`).
    init(
        location: @escaping () -> String = { "" },
        fetch: @escaping @Sendable (String) async throws -> WeatherInfo = { try await Weather.fetchWeather(location: $0) },
        now: @escaping () -> Double = { SimClock.perfMs() }
    ) {
        self.location = location
        self.fetch = fetch
        self.now = now
    }

    // MARK: - Public API (ex-`get_weather`, `get_weather_context`, `get_weather_snapshot`)

    /// Cached for 30 minutes. A failed refresh returns the stale cache (or nil).
    func getWeather() async -> WeatherInfo? {
        let loc = location()
        if loc.isEmpty { return nil }
        if cachedLocation != loc {
            cachedLocation = loc
            cachedInfo = nil
            cachedAtMs = nil
            failedAtMs = nil
        }

        // Check cache
        if let info = cachedInfo, let at = cachedAtMs, (now() - at) / 1000 < Self.cacheTTLSeconds {
            return info
        }
        // Recent failure: don't hammer (or wait on) wttr.in again yet.
        if let failed = failedAtMs, (now() - failed) / 1000 < Self.failureBackoffSeconds {
            return cachedInfo
        }

        // Fetch fresh
        do {
            let info = try await fetch(loc)
            guard cachedLocation == loc else { return info } // location changed mid-fetch
            cachedInfo = info
            cachedAtMs = now()
            failedAtMs = nil
            return info
        } catch {
            Log.info("weather", "error: Weather fetch failed: \(error)")
            if cachedLocation == loc { failedAtMs = now() }
            // Return stale cache on error
            return cachedInfo
        }
    }

    /// "WEATHER: <description> outside." for prompts, or "" without weather.
    func getWeatherContext() async -> String {
        if let info = await getWeather() {
            return "WEATHER: \(info.description) outside."
        }
        return ""
    }

    func getWeatherSnapshot() async -> WeatherSnapshot? {
        guard let info = await getWeather() else { return nil }
        return WeatherSnapshot(condition: Self.simplifyCondition(info.condition), tempC: info.tempC)
    }

    // MARK: - Network (ex-`fetch_weather`)

    /// Percent-encodes the location as a path segment: characters like '/', '?',
    /// '#' or '%' in a user-entered location would otherwise corrupt the URL and
    /// drop the `?format=j1` query. Space becomes '+'; letters, digits and
    /// `-_.~,` pass through; every other UTF-8 byte becomes `%XX`.
    nonisolated static func wttrURL(location: String) -> String {
        var encoded = ""
        for b in location.utf8 {
            switch b {
            case UInt8(ascii: " "):
                encoded += "+"
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"), UInt8(ascii: ","):
                encoded += String(UnicodeScalar(b))
            default:
                encoded += String(format: "%%%02X", b)
            }
        }
        return "https://wttr.in/\(encoded)?format=j1"
    }

    /// reqwest's `.timeout(10s)` bounds the whole request, which on URLSession
    /// is the resource timeout.
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    nonisolated static func fetchWeather(location: String, session: URLSession = Weather.session) async throws
        -> WeatherInfo
    {
        let urlString = wttrURL(location: location)
        Log.info("weather", "Fetching weather from: \(urlString)")
        guard let url = URL(string: urlString) else {
            throw PlatformError("Invalid weather URL: \(urlString)")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("co-sheep/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlatformError("Weather API returned \(http.statusCode)")
        }
        return try parseWttr(data)
    }

    // MARK: - Parsing

    private nonisolated struct WttrResponse: Decodable {
        let currentCondition: [WttrCondition]
        enum CodingKeys: String, CodingKey { case currentCondition = "current_condition" }
    }

    private nonisolated struct WttrCondition: Decodable {
        let tempC: String
        let feelsLikeC: String
        let humidity: String
        let weatherDesc: [WttrDesc]
        // Unused, but serde required it, so its absence still fails the parse.
        let weatherCode: String
        enum CodingKeys: String, CodingKey {
            case tempC = "temp_C"
            case feelsLikeC = "FeelsLikeC"
            case humidity
            case weatherDesc
            case weatherCode
        }
    }

    private nonisolated struct WttrDesc: Decodable {
        let value: String
    }

    nonisolated static func parseWttr(_ data: Data) throws -> WeatherInfo {
        let decoded = try JSONDecoder().decode(WttrResponse.self, from: data)
        guard let c = decoded.currentCondition.first else {
            throw PlatformError("No current_condition in response")
        }
        let descText = c.weatherDesc.first?.value ?? ""
        return WeatherInfo(
            condition: descText,
            description: "\(descText), \(c.tempC)C (feels like \(c.feelsLikeC)C), \(c.humidity)% humidity",
            tempC: Double(c.tempC))
    }

    /// Maps weather description to a simplified key for the overlay's effects.
    nonisolated static func simplifyCondition(_ desc: String) -> String {
        let desc = desc.lowercased()
        if desc.contains("rain") || desc.contains("drizzle") || desc.contains("shower") {
            return "rain"
        } else if desc.contains("snow") || desc.contains("blizzard") || desc.contains("sleet") || desc.contains("ice") {
            return "snow"
        } else if desc.contains("fog") || desc.contains("mist") || desc.contains("haze") {
            return "fog"
        } else if desc.contains("cloud") || desc.contains("overcast") {
            return "cloudy"
        } else {
            return "clear"
        }
    }
}
