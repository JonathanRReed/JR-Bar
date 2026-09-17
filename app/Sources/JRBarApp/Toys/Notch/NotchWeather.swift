import Foundation
import Observation
import OSLog

/// The notch card's weather: a keyless pipeline — the place comes from
/// a coarse IP lookup (ipapi.co) or the setting's own "City" text
/// geocoded by Open-Meteo, then Open-Meteo's current conditions. No
/// location permission, no API key; a refresh fails soft and the row
/// simply stays off the card.
@MainActor
@Observable
final class NotchWeather {
    /// What the row draws, once a fetch has landed.
    struct Reading: Equatable, Sendable {
        var celsius: Double
        /// The WMO weather code — `symbol` and `label` map it.
        var code: Int
        /// Where the reading is for — the IP lookup's city or the
        /// setting's text.
        var place: String
        /// What the device reports — °C for most of the world, °F in
        /// the en_US locale.
        var fahrenheit: Bool

        var temperatureText: String {
            let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
            return "\(Int(value.rounded()))°"
        }
    }

    private(set) var reading: Reading?

    /// The settings' vote — the card toggle and the city text.
    var settings: () -> (on: Bool, city: String) = { (false, "") }

    private var refresh: DispatchWorkItem?
    private var running = false
    /// The inputs the last fetch ran on — `reload` only re-reads when
    /// one moved, so a settings doc churn is not a fetch storm.
    private var lastInputs: (on: Bool, city: String)?

    static let log = Logger(subsystem: "devin.jrbar", category: "weather")
    /// Conditions shift slower than the card opens — half an hour.
    static let interval: TimeInterval = 30 * 60

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
        if let last = lastInputs, last.on == now.on, last.city == now.city { return }
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
        lastInputs = (on, city)
        guard on else { reading = nil; schedule(); return }
        Task { [weak self] in
            let found = await Self.fetch(city: city)
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

    /// The fetch: city text geocoded, or the IP's coarse fix, then the
    /// current reading. Both endpoints are plain HTTPS and keyless.
    static func fetch(city: String) async -> Reading? {
        guard let whereabouts = await locate(city: city) else { return nil }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(whereabouts.lat)),
            URLQueryItem(name: "longitude", value: String(whereabouts.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let celsius = current["temperature_2m"] as? Double,
              let code = (current["weather_code"] as? Int) ?? (current["weather_code"] as? Double).map(Int.init)
        else { return nil }
        return Reading(celsius: celsius, code: code, place: whereabouts.name,
                       fahrenheit: Locale.current.measurementSystem == .us)
    }

    private static func locate(city: String) async -> (lat: Double, lon: Double, name: String)? {
        let text = city.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return await locateByIP() }
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

    /// Coarse IP geolocation — city-scale accuracy, no permission.
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
