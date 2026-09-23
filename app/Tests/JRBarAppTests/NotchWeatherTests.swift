import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The weather row's privacy rule and its reading, without the network:
/// an empty city never phones the IP service unless the person opted
/// in, and Open-Meteo's document reduces to conditions, today's range
/// and the next rain.
@Suite("Notch weather")
@MainActor
struct NotchWeatherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a typed city geocodes; an empty one asks nobody unless the IP lookup is allowed")
    func source() {
        #expect(NotchWeather.source(city: "London", allowIP: false) == .city("London"))
        #expect(NotchWeather.source(city: "  Paris ", allowIP: true) == .city("Paris"))
        #expect(NotchWeather.source(city: "", allowIP: false) == nil)
        #expect(NotchWeather.source(city: "   ", allowIP: false) == nil)
        #expect(NotchWeather.source(city: "", allowIP: true) == .ipLookup)
        #expect(!NotchSettings().weatherUseIPLocation, "the IP lookup is never the default")
    }

    @Test("the forecast request carries the range and the minutely rain in one keyless call")
    func request() throws {
        let url = try #require(NotchWeather.forecastURL(lat: 51.5, lon: -0.12))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "api.open-meteo.com")
        #expect(names["daily"] == "temperature_2m_max,temperature_2m_min")
        #expect(names["minutely_15"] == "precipitation")
        #expect(names["timeformat"] == "unixtime")
        #expect(names["apikey"] == nil)
    }

    private func document(rain: [Double], firstSlotOffset: TimeInterval = 0) -> [String: Any] {
        let start = now.timeIntervalSince1970 + firstSlotOffset
        return [
            "current": ["temperature_2m": 18.4, "weather_code": 2],
            "daily": ["temperature_2m_max": [21.2], "temperature_2m_min": [11.6]],
            "minutely_15": [
                "time": rain.indices.map { start + Double($0) * 900 },
                "precipitation": rain,
            ],
        ]
    }

    @Test("conditions, today's range and the first wet slot")
    func parse() throws {
        let dry = try #require(NotchWeather.parse(document(rain: [0, 0, 0, 0]), place: "London",
                                                  fahrenheit: false, now: now))
        #expect(dry.temperatureText == "18°")
        #expect(dry.rainInMinutes == nil)
        #expect(dry.outlookText == "H 21° L 12°")

        let soon = try #require(NotchWeather.parse(document(rain: [0, 0, 0.4, 1.2]), place: "London",
                                                   fahrenheit: false, now: now))
        #expect(soon.rainInMinutes == 30)
        #expect(soon.outlookText == "H 21° L 12° · rain in 30 min")

        // The current slot started ten minutes ago and is wet.
        let now_ = try #require(NotchWeather.parse(document(rain: [0.3, 0], firstSlotOffset: -600),
                                                   place: "London", fahrenheit: false, now: now))
        #expect(now_.rainInMinutes == 0)
        #expect(now_.outlookText?.hasSuffix("raining now") == true)

        let us = try #require(NotchWeather.parse(document(rain: []), place: "Austin",
                                                 fahrenheit: true, now: now))
        #expect(us.temperatureText == "65°")
        #expect(us.outlookText == "H 70° L 53°")
    }

    @Test("a document without current conditions is no reading")
    func malformed() {
        #expect(NotchWeather.parse([:], place: "", fahrenheit: false, now: now) == nil)
        #expect(NotchWeather.parse(["current": ["temperature_2m": 3.0]], place: "",
                                   fahrenheit: false, now: now) == nil)
        let bare = NotchWeather.parse(["current": ["temperature_2m": 3, "weather_code": 0]],
                                      place: "", fahrenheit: false, now: now)
        #expect(bare?.outlookText == nil, "no forecast arrays: no outlook line")
    }
}
