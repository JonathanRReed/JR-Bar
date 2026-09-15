import Foundation
import Testing
@testable import JRBarCore

/// `DockSettings` is the Dock utility's half of `app-state.json`
/// (docs/TOY-PARITY.md "Dock — Replace mode"): it must round-trip
/// cleanly and read tolerantly the way `ToysState` does — a missing or
/// mistyped key falls back to its default and a newer build's keys are
/// ignored. The magnification curve is pinned here too.
@Suite("Dock settings")
struct DockSettingsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults: off, replace mode, bottom edge, floating glass, quiet")
    func defaults() {
        let s = DockSettings()
        #expect(s.enabled == false)
        #expect(s.mode == .replace, "replace is the only built mode — an enabled card must show something")
        #expect(s.edge == .bottom)
        #expect(s.displayPolicy == .main)
        #expect(s.iconSize == 56)
        #expect(s.magnification == DockMagnification())
        #expect(s.magnification.enabled == false)
        #expect(s.material == .glass)
        #expect(s.style == .floating)
        #expect(s.tintHex == nil)
        #expect(s.autoHide == DockAutoHide())
        #expect(s.runningIndicator == .dot)
        #expect(s.pinned.isEmpty)
        #expect(s.showFinder == true)
        #expect(s.seededFromAppleDock == false)
    }

    @Test("encode then decode returns the same settings")
    func roundTrip() throws {
        var s = DockSettings()
        s.enabled = true
        s.mode = .enhance
        s.edge = .left
        s.displayPolicy = .perDisplay
        s.iconSize = 44
        s.magnification = DockMagnification(enabled: true, scale: 1.8, reach: 200)
        s.material = .frosted
        s.style = .fullWidth
        s.tintHex = "#33aaFF"
        s.autoHide = DockAutoHide(enabled: true, delay: 1.25)
        s.runningIndicator = .card
        s.pinned = ["com.apple.Safari", "com.apple.finder"]
        s.showFinder = false
        s.seededFromAppleDock = true
        #expect(try decode(DockSettings.self, encode(s)) == s)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(DockSettings.self, "{}") == DockSettings())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"enabled": true, "mode": "levitate", "edge": "top", "displayPolicy": "everywhere", "iconSize": "huge", "magnification": {"enabled": "yes", "scale": "lots"}, "material": "chrome", "style": "orbiting", "tintHex": "not a colour", "autoHide": {"enabled": true, "delay": "later"}, "runningIndicator": "fireworks", "pinned": "many", "showFinder": "no", "futureDockKey": {"x": 1}}"#
        let s = try decode(DockSettings.self, json)
        #expect(s.enabled == true)
        #expect(s.mode == .replace, "an unknown mode falls back, not crashes")
        #expect(s.edge == .bottom, "a top-edge dock is not ours to draw")
        #expect(s.displayPolicy == .main)
        #expect(s.iconSize == DockSettings.defaultIconSize, "a string is not a size")
        #expect(s.magnification.enabled == false)
        #expect(s.magnification.scale == DockMagnification.defaultScale)
        #expect(s.material == .glass)
        #expect(s.style == .floating)
        #expect(s.tintHex == nil, "malformed hex is no tint")
        #expect(s.autoHide.enabled == true)
        #expect(s.autoHide.delay == DockAutoHide.defaultDelay)
        #expect(s.runningIndicator == .dot)
        #expect(s.pinned.isEmpty)
        #expect(s.showFinder == true)
    }

    @Test("values are clamped to the card's ranges")
    func clamps() throws {
        let s = try decode(DockSettings.self,
            #"{"iconSize": 4000, "magnification": {"scale": 9, "reach": -5}, "autoHide": {"delay": 99}}"#)
        #expect(s.iconSize == DockSettings.iconSizeRange.upperBound)
        #expect(s.magnification.scale == DockMagnification.scaleRange.upperBound)
        #expect(s.magnification.reach == DockMagnification.reachRange.lowerBound)
        #expect(s.autoHide.delay == DockAutoHide.delayRange.upperBound)
    }

    @Test("pins decode deduped and empties dropped")
    func pinsDeduped() throws {
        let s = try decode(DockSettings.self,
            #"{"pinned": ["a.b", "", "a.b", "c.d"]}"#)
        #expect(s.pinned == ["a.b", "c.d"])
    }

    @Test("tint hex is normalized to canonical #RRGGBB")
    func tintNormalized() throws {
        let s = try decode(DockSettings.self, #"{"tintHex": "33aaff"}"#)
        #expect(s.tintHex == "#33AAFF")
    }

    // MARK: The magnification wave

    @Test("the wave peaks under the pointer and dies at reach")
    func magnificationCurve() {
        #expect(DockMagnification.magnificationFactor(distance: 0, scale: 1.6, reach: 140) == 1.6,
                "dead centre is full scale")
        #expect(DockMagnification.magnificationFactor(distance: 140, scale: 1.6, reach: 140) == 1,
                "at reach the lift is gone")
        #expect(DockMagnification.magnificationFactor(distance: 500, scale: 1.6, reach: 140) == 1,
                "past reach is flat")
        #expect(DockMagnification.magnificationFactor(distance: -20, scale: 1.6, reach: 140)
                == DockMagnification.magnificationFactor(distance: 20, scale: 1.6, reach: 140),
                "the wave is symmetric")
    }

    @Test("the wave falls off monotonically")
    func magnificationMonotonic() {
        var previous = DockMagnification.magnificationFactor(distance: 0, scale: 2.0, reach: 100)
        for d in stride(from: 1.0, through: 100.0, by: 1.0) {
            let next = DockMagnification.magnificationFactor(distance: d, scale: 2.0, reach: 100)
            #expect(next <= previous + 1e-9, "distance \(d) must not lift harder than \(d - 1)")
            previous = next
        }
    }

    @Test("degenerate inputs are a flat bar")
    func magnificationDegenerate() {
        #expect(DockMagnification.magnificationFactor(distance: 0, scale: 1, reach: 140) == 1,
                "scale 1 is off")
        #expect(DockMagnification.magnificationFactor(distance: 0, scale: 1.6, reach: 0) == 1,
                "no reach is no wave")
        #expect(DockMagnification.magnificationFactor(distance: .nan, scale: 1.6, reach: 140) == 1)
        #expect(DockMagnification.magnificationFactor(distance: .infinity, scale: 1.6, reach: 140) == 1)
    }
}
