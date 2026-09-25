import Foundation
import FoundationModels
import Synchronization

@Generable
struct WeatherArguments: Sendable {
    @Guide(description: "City or place, only if the user named one, e.g. \"Paris\"")
    var place: String?
    @Guide(description: "Which day", .anyOf(["today", "tomorrow"]))
    var day: String
}

/// Answers weather questions aloud: now, the day's high and low, and the
/// chance of rain. Uses Open-Meteo (free, no key, no account): Apple's
/// WeatherKit needs a paid developer membership this personally-signed app
/// doesn't have. Only a city name leaves the Mac; no AI runs in the cloud.
struct WeatherTool: AssistantTool {
    let name = "getWeather"
    let title = "Weather"
    let symbol = "cloud.sun"
    let keywords: Set<String> = ["weather", "temperature", "rain", "raining", "forecast", "hot", "cold", "sunny", "umbrella", "degrees", "warm", "snow", "snowing", "outside"]
    let description = """
        Tell the weather: now, the high and low, and the chance of rain. \
        "how's the weather" → day "today". "will it rain tomorrow in Paris" → day "tomorrow", place "Paris".
        """
    let requiresNetwork = true
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: WeatherArguments) -> String {
        [arguments.place ?? WeatherSettings.city, arguments.day == "tomorrow" ? "tomorrow" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: WeatherArguments) async throws -> ToolResult {
        // A place the user didn't say is the model's guess: use the home city.
        var place = arguments.place?.trimmingCharacters(in: .whitespaces) ?? ""
        if place.isEmpty || !(CommandContext.transcript.map { Grounding.mentions(place, in: $0) } ?? true) {
            place = WeatherSettings.city
        }
        let tomorrow = arguments.day == "tomorrow"
            && (CommandContext.transcript.map { Grounding.mentions("tomorrow", in: $0) } ?? true)
        let location = try await OpenMeteo.locate(place)
        let forecast = try await OpenMeteo.forecast(for: location, fahrenheit: WeatherSettings.usesFahrenheit)
        return ToolResult(Self.answer(forecast, place: location.name, tomorrow: tomorrow), isAnswer: true)
    }

    /// "It's 21° and clear in Amsterdam. High 22°, low 11°." Pure, for testing.
    static func answer(_ forecast: OpenMeteo.Forecast, place: String, tomorrow: Bool) -> String {
        let day = tomorrow ? 1 : 0
        guard forecast.highs.indices.contains(day), forecast.lows.indices.contains(day) else {
            return "I couldn't get the forecast for \(place)"
        }
        let high = Int(forecast.highs[day].rounded()), low = Int(forecast.lows[day].rounded())
        let rain = forecast.rainChances.indices.contains(day) ? forecast.rainChances[day] : 0
        let rainNote = rain >= 20 ? " \(rain)% chance of rain." : ""
        if tomorrow {
            let conditions = describe(forecast.codes.indices.contains(1) ? forecast.codes[1] : forecast.currentCode)
            return "Tomorrow in \(place): \(conditions), high \(high)°, low \(low)°.\(rainNote)"
        }
        let now = Int(forecast.currentTemperature.rounded())
        return "It's \(now)° and \(describe(forecast.currentCode)) in \(place). High \(high)°, low \(low)°.\(rainNote)"
    }

    /// WMO weather codes, as Open-Meteo reports them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1: "mostly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "foggy"
        case 51, 53, 55: "drizzly"
        case 56, 57: "freezing drizzle"
        case 61, 63: "rainy"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71, 73, 75, 77: "snowy"
        case 80, 81: "showery"
        case 82: "heavy showers"
        case 85, 86: "snow showers"
        case 95: "stormy"
        case 96, 99: "stormy with hail"
        default: "unsettled"
        }
    }

    // MARK: Direct phrasings

    private static let triggers: Set<String> = ["weather", "temperature", "forecast", "rain", "raining", "umbrella", "snow", "snowing"]

    /// "how's the weather", "what's the weather in Paris tomorrow",
    /// "will it rain tomorrow". Not "search for the weather" (a web search).
    func directArguments(for command: DirectCommand) -> WeatherArguments? {
        let words = command.text.split(separator: " ").map(String.init)
        guard !Set(words).isDisjoint(with: Self.triggers),
              !["search", "google", "look"].contains(words.first ?? ""),
              words.count <= 12
        else { return nil }
        let tomorrow = words.contains("tomorrow")
        var place: String?
        if let index = words.lastIndex(of: "in"), index + 1 < words.count {
            let after = words[(index + 1)...].filter { !["today", "tomorrow", "right", "now", "the"].contains($0) }
            if !after.isEmpty { place = after.joined(separator: " ") }
        }
        return WeatherArguments(place: place, day: tomorrow ? "tomorrow" : "today")
    }
}

/// The user's home city and units.
public enum WeatherSettings {
    public static let cityKey = "weather.city"

    /// The chosen city, else the one in the Mac's time zone ("Europe/Amsterdam").
    public static var city: String {
        if let city = UserDefaults.standard.string(forKey: cityKey)?.trimmingCharacters(in: .whitespaces), !city.isEmpty {
            return city
        }
        return defaultCity
    }

    public static var defaultCity: String {
        (TimeZone.current.identifier.split(separator: "/").last.map(String.init) ?? "London").replacingOccurrences(of: "_", with: " ")
    }

    static var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }
}

enum OpenMeteo {
    struct Location: Sendable, Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct Forecast: Sendable, Equatable {
        let currentTemperature: Double
        let currentCode: Int
        let highs: [Double]
        let lows: [Double]
        let codes: [Int]
        let rainChances: [Int]
    }

    private static let cache = Mutex<[String: Location]>([:])

    static func locate(_ place: String) async throws -> Location {
        let key = place.lowercased()
        if let cached = cache.withLock({ $0[key] }) { return cached }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1"), .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        struct Response: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let results: [Result]?
        }
        let response: Response = try await get(components.url!)
        guard let first = response.results?.first else { throw ToolError("I couldn't find a place called \(place)") }
        let location = Location(name: first.name, latitude: first.latitude, longitude: first.longitude)
        cache.withLock { $0[key] = location }
        return location
    }

    static func forecast(for location: Location, fahrenheit: Bool) async throws -> Forecast {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(location.latitude)),
            .init(name: "longitude", value: String(location.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable {
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let weather_code: [Int]
                let precipitation_probability_max: [Int?]?
            }
            let current: Current
            let daily: Daily
        }
        let response: Response = try await get(components.url!)
        return Forecast(
            currentTemperature: response.current.temperature_2m,
            currentCode: response.current.weather_code,
            highs: response.daily.temperature_2m_max,
            lows: response.daily.temperature_2m_min,
            codes: response.daily.weather_code,
            rainChances: (response.daily.precipitation_probability_max ?? []).map { $0 ?? 0 }
        )
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError("The weather service didn't answer") }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw ToolError("The weather needs the internet, and this Mac is offline")
        }
    }
}
