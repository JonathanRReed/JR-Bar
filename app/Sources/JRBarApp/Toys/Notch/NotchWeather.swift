import Foundation
import Observation
import OSLog

/// The notch card's weather: a keyless pipeline — the place is the
/// setting's own "City" text geocoded by Open-Meteo, then Open-Meteo's
/// current conditions, today's high and low and the next two hours'
/// rain. No location permission, no API key. Where the city is empty
/// the row stays off unless the person opted in to a coarse IP lookup
/// (ipapi.co) — that sends their IP to a second third party, so it is
/// never the silent default. A refresh fails soft and the row simply
/// stays off the card.
@MainActor
@Observable
final class NotchWeather {
    /// What the row draws, once a fetch has landed.
    struct Reading: Equatable, Sendable {
        var celsius: Double
        /// The WMO weather code — `symbol` and `label` map it.
        var code: Int
        /// Where the reading is for — the geocoded city, or the IP
        /// lookup's when the person allowed it.
        var place: String
        /// What the device reports — °C for most of the world, °F in
        /// the en_US locale.
        var fahrenheit: Bool
        /// Today's high and low, when the forecast carried them.
        var highCelsius: Double?
        var lowCelsius: Double?
        /// Minutes until rain starts inside the next two hours — 0 is
        /// raining now; nil is a dry two hours (or no minutely data).
        var rainInMinutes: Int?

        init(celsius: Double, code: Int, place: String, fahrenheit: Bool,
             highCelsius: Double? = nil, lowCelsius: Double? = nil, rainInMinutes: Int? = nil) {
            self.celsius = celsius
            self.code = code
            self.place = place
            self.fahrenheit = fahrenheit
            self.highCelsius = highCelsius
            self.lowCelsius = lowCelsius
            self.rainInMinutes = rainInMinutes
        }

        private func degrees(_ celsius: Double) -> String {
            let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
            return "\(Int(value.rounded()))°"
        }

        var temperatureText: String { degrees(celsius) }

        /// "H 21° L 12° · rain in 40 min" — the second line; nil when
        /// the forecast carried neither.
        var outlookText: String? {
            var parts: [String] = []
            if let highCelsius, let lowCelsius {
                parts.append("H \(degrees(highCelsius)) L \(degrees(lowCelsius))")
            }
            if let rainInMinutes {
                parts.append(rainInMinutes == 0 ? "raining now" : "rain in \(rainInMinutes) min")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private(set) var reading: Reading?

    /// The settings' vote — the card toggle and the city text.
    var settings: () -> (on: Bool, city: String) = { (false, "") }
    /// The person's opt-in to the coarse IP lookup when no city is
    /// typed. Off unless wired and switched on — the default never
    /// sends the IP anywhere.
    var allowIPLocation: () -> Bool = { false }

    private var refresh: DispatchWorkItem?
    private var running = false
    /// The inputs the last fetch ran on — `reload` only re-reads when
    /// one moved, so a settings doc churn is not a fetch storm.
    private var lastInputs: (on: Bool, city: String, ip: Bool)?

    static let log = Logger(subsystem: "devin.jrbar", category: "weather")
    /// Conditions shift slower than the card opens — half an hour.
    static let interval: TimeInterval = 30 * 60
    /// The rain lookahead: eight fifteen-minute slots.
    static let rainSlots = 8

    func start() {
        guard !running else { return }
        running = true
        tick()
    }

    /// A settings change re-reads the pipeline immediately so a city
    /// edit lands on the next card open, not thirty minutes from now.
    func reload() {
        guard running else { return }
        let now = settings()
        let ip = allowIPLocation()
        if let last = lastInputs, last.on == now.on, last.city == now.city, last.ip == ip { return }
        refresh?.cancel()
        tick()
    }

    func stop() {
        running = false
        refresh?.cancel()
        refresh = nil
    }

    private func tick() {
        let (on, city) = settings()
        let ip = allowIPLocation()
        lastInputs = (on, city, ip)
        guard on else { reading = nil; schedule(); return }
        Task { [weak self] in
            let found = await Self.fetch(city: city, allowIP: ip)
            await MainActor.run { self?.reading = found }
            self?.schedule()
        }
    }

    private func schedule() {
        guard running else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval, execute: work)
    }

    /// WMO weather code → (symbol, label) — the same icons the island
    /// uses elsewhere.
    static func symbol(for code: Int) -> (String, String) {
        switch code {
        case 0: return ("sun.max.fill", "Clear")
        case 1: return ("sun.max.fill", "Mostly clear")
        case 2: return ("cloud.sun.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Overcast")
        case 45, 48: return ("cloud.fog.fill", "Fog")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 65, 66, 67: return ("cloud.rain.fill", "Rain")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Snow")
        case 80, 81, 82: return ("cloud.heavyrain.fill", "Showers")
        case 85, 86: return ("cloud.snow.fill", "Snow showers")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm")
        default: return ("cloud.fill", "Weather")
        }
    }

    /// Where the fetch would ask for a place, or nil when it must not
    /// ask at all: a typed city geocodes, an empty one uses the IP only
    /// with the opt-in. Pure, so the privacy rule is pinned.
    enum Source: Equatable {
        case city(String)
        case ipLookup
    }

    static func source(city: String, allowIP: Bool) -> Source? {
        let text = city.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return .city(text) }
        return allowIP ? .ipLookup : nil
    }

    /// The forecast request: current conditions, today's range and the
    /// next two hours in fifteen-minute slots — one keyless call.
    static func forecastURL(lat: Double, lon: Double) -> URL? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "forecast_minutely_15", value: String(rainSlots)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return parts.url
    }

    /// Open-Meteo's answer → a reading. Pure: the tests hand it a
    /// document, no network.
    static func parse(_ json: [String: Any], place: String, fahrenheit: Bool,
                      now: Date) -> Reading? {
        func number(_ any: Any?) -> Double? {
            (any as? Double) ?? (any as? Int).map(Double.init) ?? (any as? NSNumber)?.doubleValue
        }
        guard let current = json["current"] as? [String: Any],
              let celsius = number(current["temperature_2m"]),
              let code = number(current["weather_code"]).map({ Int($0) }) else { return nil }
        let daily = json["daily"] as? [String: Any]
        let high = (daily?["temperature_2m_max"] as? [Any])?.first.flatMap(number)
        let low = (daily?["temperature_2m_min"] as? [Any])?.first.flatMap(number)
        var rain: Int?
        if let minutely = json["minutely_15"] as? [String: Any],
           let times = minutely["time"] as? [Any],
           let amounts = minutely["precipitation"] as? [Any] {
            for (time, amount) in zip(times, amounts) {
                guard let at = number(time), let mm = number(amount) else { continue }
                // A slot that already ended is history.
                guard at + 15 * 60 > now.timeIntervalSince1970 else { continue }
                if mm >= 0.1 {
                    rain = max(0, Int(((at - now.timeIntervalSince1970) / 60).rounded()))
                    break
                }
            }
        }
        return Reading(celsius: celsius, code: code, place: place, fahrenheit: fahrenheit,
                       highCelsius: high, lowCelsius: low, rainInMinutes: rain)
    }

    /// The fetch: the place first, then the forecast. Both endpoints
    /// are plain HTTPS and keyless.
    static func fetch(city: String, allowIP: Bool) async -> Reading? {
        guard let source = source(city: city, allowIP: allowIP),
              let whereabouts = await locate(source),
              let url = forecastURL(lat: whereabouts.lat, lon: whereabouts.lon),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(json, place: whereabouts.name,
                     fahrenheit: Locale.current.measurementSystem == .us, now: Date())
    }

    private static func locate(_ source: Source) async -> (lat: Double, lon: Double, name: String)? {
        switch source {
        case .ipLookup:
            return await locateByIP()
        case .city(let text):
            // A named city geocodes through Open-Meteo's search.
            var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            parts.queryItems = [
                URLQueryItem(name: "name", value: text),
                URLQueryItem(name: "count", value: "1"),
            ]
            guard let url = parts.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let lat = first["latitude"] as? Double,
                  let lon = first["longitude"] as? Double
            else { return nil }
            let name = first["name"] as? String ?? text
            return (lat, lon, name)
        }
    }

    /// Coarse IP geolocation — city-scale accuracy, no permission, and
    /// only ever with the person's opt-in (`allowIPLocation`).
    private static func locateByIP() async -> (lat: Double, lon: Double, name: String)? {
        guard let url = URL(string: "https://ipapi.co/json/"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lat = (json["latitude"] as? Double) ?? (json["latitude"] as? String).flatMap(Double.init),
              let lon = (json["longitude"] as? Double) ?? (json["longitude"] as? String).flatMap(Double.init)
        else { return nil }
        return (lat, lon, json["city"] as? String ?? "")
    }
}
