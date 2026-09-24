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
}
