import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The burst's colours: whose tint it wears, and what each palette deals.
@Suite("Confetti palette")
@MainActor
struct ConfettiPaletteTests {
    /// sRGB components, so two colours built different ways compare.
    private func rgb(_ color: Color) -> [Double] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [ns.redComponent, ns.greenComponent, ns.blueComponent].map { Double($0) }
    }

    private func same(_ a: Color, _ b: Color) -> Bool {
        zip(rgb(a), rgb(b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    @Test("no provider, an empty one or an unknown one wears the Toys tint, never grey")
    func unknownIsTheToysTint() {
        for provider in [nil, "", "foo"] as [String?] {
            let tint = ConfettiView.burstTint(provider: provider, document: nil)
            #expect(same(tint, ConfettiView.toysTint), "\(provider ?? "nil") must not be grey")
        }
        #expect(!same(ConfettiView.burstTint(provider: "foo", document: nil),
                      ProviderStyle.style(for: "foo").accent))
    }

    @Test("a known provider wears its accent, whatever its case")
    func knownProvider() {
        let codex = ProviderStyle.style(for: "codex").accent
        #expect(same(ConfettiView.burstTint(provider: "codex", document: nil), codex))
        #expect(same(ConfettiView.burstTint(provider: "Codex", document: nil), codex))
    }

    @Test("a colour set in agent_colors wins, even for a provider the app doesn't know")
    func configuredColourWins() {
        let document = SettingsDocument(["colors": ["agent_colors": [
            "codex": "#112233", "foo": "#445566",
        ]]])
        let expected = Color(nsColor: NSColor(hex: "#112233") ?? .black)
        #expect(same(ConfettiView.burstTint(provider: "codex", document: document), expected))
        let foo = Color(nsColor: NSColor(hex: "#445566") ?? .black)
        #expect(same(ConfettiView.burstTint(provider: "foo", document: document), foo))
    }

    @Test("every palette deals at least four distinct colours", arguments: ConfettiPalette.allCases)
    func paletteIsRich(_ palette: ConfettiPalette) {
        let look = ConfettiView.look(palette, tint: ProviderStyle.style(for: "claude").accent, provider: "claude",
                                     everyone: [("claude", ProviderStyle.style(for: "claude").accent),
                                                ("codex", ProviderStyle.style(for: "codex").accent)])
        let distinct = Set(look.slots.map { rgb($0).map { Int(($0 * 255).rounded()) } })
        #expect(distinct.count >= 4, "\(palette) deals \(distinct.count) colours")
        #expect(look.weights.count == look.slots.count)
        #expect(look.weights.allSatisfy { $0 > 0 })
    }

    @Test("Everyone is the working providers' accents, each with its glyph")
    func everyoneIsTheWorkingProviders() {
        let working = [("claude", ProviderStyle.style(for: "claude").accent),
                       ("gemini", ProviderStyle.style(for: "gemini").accent)]
        let look = ConfettiView.look(.everyone, tint: ConfettiView.toysTint, provider: nil,
                                     everyone: working.map { (id: $0.0, color: $0.1) })
        #expect(same(look.slots[0], working[0].1) && same(look.slots[1], working[1].1))
        #expect(look.glyphs == [.symbol("asterisk"), .symbol("sparkle")])
        // Nobody working: the burst's own colour instead.
        let alone = ConfettiView.look(.everyone, tint: ProviderStyle.style(for: "codex").accent, provider: "codex")
        #expect(same(alone.slots[0], ProviderStyle.style(for: "codex").accent))
    }

    @Test("in Everyone, each provider's glyph wears that provider's colour")
    func everyoneGlyphsWearTheirOwnColour() {
        let working = ["claude", "codex", "gemini"].map { (id: $0, color: ProviderStyle.style(for: $0).accent) }
        let look = ConfettiView.look(.everyone, tint: ConfettiView.toysTint, provider: nil, everyone: working)
        for shapes in [ConfettiShapes.glyphs, .mixed] {
            let recipe = ConfettiBurst.Recipe(shapes: shapes, slotWeights: look.weights, glyphs: look.glyphs.count)
            let burst = ConfettiBurst(stage: .reference, recipe: recipe, seed: 9)
            let marks = burst.pieces.filter { $0.shape == .glyph }
            #expect(!marks.isEmpty)
            for piece in marks {
                #expect(piece.slot == piece.glyph, "glyph \(piece.glyph) in slot \(piece.slot)'s colour")
            }
            #expect(Set(marks.map(\.glyph)).count == 3, "every working provider's mark is thrown")
        }
    }

    @Test("the provider palette leads with the tint and keeps its deep shade for the backs")
    func providerSteps() {
        let tint = ProviderStyle.style(for: "claude").accent
        let look = ConfettiView.look(.provider, tint: tint, provider: "claude")
        #expect(same(look.slots[0], tint))
        #expect(look.weights[0] == look.weights.max())
        let deep = ConfettiView.deeper(tint)
        #expect(!look.slots.contains { same($0, deep) }, "the deeper shade is a back, never a face")
        #expect(look.glyphs == [.symbol("asterisk")])
        // A lit face is brighter than its own back at the same light.
        let face = look.paper(far: false, front: true, slot: 0, shade: 1)
        let back = look.paper(far: false, front: false, slot: 0, shade: 1)
        #expect(face.red + face.green + face.blue > back.red + back.green + back.blue)
    }

    @Test("Mono is the tint alone")
    func monoIsOneHue() {
        let look = ConfettiView.look(.mono, tint: ProviderStyle.style(for: "codex").accent, provider: "codex")
        let hues = look.slots.compactMap { NSColor($0).usingColorSpace(.deviceRGB)?.hueComponent }
        #expect(hues.allSatisfy { abs($0 - hues[0]) < 0.02 })
    }

    @Test("the seasons fall on their days, from the local calendar")
    func seasons() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        func day(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)))
        }
        #expect(ConfettiSeason.on(try day(2026, 12, 31), calendar: calendar) == .newYear)
        #expect(ConfettiSeason.on(try day(2027, 1, 1), calendar: calendar) == .newYear)
        #expect(ConfettiSeason.on(try day(2027, 2, 14), calendar: calendar) == .valentine)
        #expect(ConfettiSeason.on(try day(2026, 10, 31), calendar: calendar) == .halloween)
        #expect(ConfettiSeason.on(try day(2026, 12, 25), calendar: calendar) == .christmas)
        // Easter Sunday 2027 is 28 March; Lunar New Year 2027 is 6 February.
        #expect(ConfettiSeason.easterSunday(2027).map { [$0.month, $0.day] } == [3, 28])
        #expect(ConfettiSeason.on(try day(2027, 3, 28), calendar: calendar) == .easter)
        #expect(ConfettiSeason.on(try day(2027, 2, 6), calendar: calendar) == .lunarNewYear)
        #expect(ConfettiSeason.on(try day(2026, 9, 24), calendar: calendar) == nil, "an ordinary day")
        #expect(ConfettiSeason.valentine.special == .heart)
        let look = ConfettiView.look(.provider, tint: .red, provider: "claude", season: .halloween)
        #expect(look.glyphs.isEmpty, "a holiday swaps the glyph for its own fleck")
    }

    @Test("an older file's Rainbow reads as Party; nothing reads as an unknown palette")
    func rainbowIsParty() throws {
        let decoded = try JSONDecoder().decode([ConfettiPalette].self, from: Data(#"["rainbow", "party", "gold"]"#.utf8))
        #expect(decoded == [.party, .party, .gold])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ConfettiPalette].self, from: Data(#"["neon"]"#.utf8))
        }
        let encoded = try JSONEncoder().encode([ConfettiPalette.party])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["party"]"#)
    }
}
