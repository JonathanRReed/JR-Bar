import AppKit
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore
@testable import JRBarUI

/// Every provider the app names draws its real mark, on every surface,
/// in an ink that clears 3:1 where it sits.
@Suite("Provider marks")
struct ProviderMarkTests {
    /// Every agent the settings know, the two usage sources and JR-Bar's
    /// own background rows.
    static let knownProviders = SettingsKey.providers + ["openai-api", "t3code", "jrbar"]

    @Test func everyKnownProviderHasItsRealMark() throws {
        for provider in Self.knownProviders {
            let style = ProviderStyle.style(for: provider)
            guard case .logo(let id) = style.glyph else {
                Issue.record("\(provider) still draws \(style.glyph)")
                continue
            }
            let logo = try #require(ProviderLogo.named(id), "\(provider)'s mark \(id) does not load")
            let bounds = logo.unitPath.boundingBoxOfPath
            #expect(bounds.width > 0.3 && bounds.height > 0.2, "\(id) is \(bounds)")
            guard case .logo(let drawn) = style.mark else {
                Issue.record("\(provider) resolves to its fallback")
                continue
            }
            #expect(drawn === logo)
            #expect(style.fallback != .symbol(ProviderStyle.unknownSymbol), "\(provider) keeps its old glyph")
        }
    }

    @Test func theDefaultsFollowTheRequest() {
        // Codex and the OpenAI API wear the OpenAI blossom; OpenClaw its
        // menu-bar critter; JR-Bar its own notch cap.
        #expect(ProviderStyle.style(for: "codex").glyph == .logo("openai"))
        #expect(ProviderStyle.style(for: "openai-api").glyph == .logo("openai"))
        #expect(ProviderStyle.style(for: "openclaw").glyph == .logo("openclaw"))
        #expect(ProviderStyle.style(for: "jrbar").glyph == .logo("jrbar"))
        // The alternatives stay in the data, so a default can flip.
        for alternative in ["codex", "xai", "openclaw.molty", "gemini.lobe"] {
            #expect(ProviderLogo.named(alternative) != nil, "\(alternative)")
        }
    }

    @Test func anUnknownProviderKeepsANeutralSymbol() {
        let style = ProviderStyle.style(for: "Mystery")
        #expect(style.glyph == .symbol(ProviderStyle.unknownSymbol))
        #expect(style.name == "Mystery")
        guard case .symbol(let name) = style.mark else {
            Issue.record("an unknown provider drew \(style.mark)")
            return
        }
        #expect(name == ProviderStyle.unknownSymbol)
    }

    @Test func aMarkThatWillNotLoadFallsBackToTheOldGlyph() {
        let broken = ProviderStyle(id: "kiro", name: "Kiro", accentHex: "#A00848", glyph: .logo("no-such-mark"),
                                   fallback: .text("K"))
        guard case .text(let letters) = broken.mark else {
            Issue.record("drew \(broken.mark)")
            return
        }
        #expect(letters == "K")
        // A configured colour keeps the mark and the fallback.
        let styled = ProviderStyle.style(for: "codex", document: nil)
        #expect(styled.glyph == .logo("openai") && styled.fallback == ProviderStyle.style(for: "codex").fallback)
    }

    @MainActor @Test func theMenuBarMeterCarriesTheProvidersMark() {
        #expect(StatusItemController.meter(for: "codex", fraction: 0.5, approximate: false).glyph == .logo("openai"))
        #expect(StatusItemController.meter(for: "claude", fraction: 0.5, approximate: false).glyph == .logo("claude"))
        #expect(StatusItemController.meter(for: "mystery", fraction: 0.5, approximate: false).glyph
            == .symbol(ProviderStyle.unknownSymbol))
        let samples = StatusItemController.sampleMeters.map(\.glyph)
        #expect(samples == [.logo("claude"), .logo("openai"), .logo("gemini"), .logo("devin")])
    }

    // MARK: Ink

    static func rgb(_ color: NSColor) -> ProviderMarkInk.RGB {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return ProviderMarkInk.RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    @Test func everyMarksInkClearsTheFloorOnEverySurface() {
        let floor = ProviderMarkInk.minimumContrast - 0.001
        for provider in Self.knownProviders {
            let accent = Self.rgb(ProviderStyle.style(for: provider).nsAccent)
            let darkPlate = ProviderMarkInk.plate(accent, over: ProviderMarkInk.darkSurface)
            let lightPlate = ProviderMarkInk.plate(accent, over: ProviderMarkInk.lightSurface)
            let blackPlate = ProviderMarkInk.plate(accent, over: .black)
            let dark = ProviderMarkInk.ink(accent, on: .darkPlate)
            let light = ProviderMarkInk.ink(accent, on: .lightPlate)
            let bare = ProviderMarkInk.ink(accent, on: .black)
            #expect(dark.contrast(with: darkPlate) >= floor, "\(provider) on a dark tile")
            #expect(dark.contrast(with: blackPlate) >= floor, "\(provider) on a tile in the notch")
            #expect(light.contrast(with: lightPlate) >= floor, "\(provider) on a light tile")
            #expect(light.contrast(with: blackPlate) >= floor, "\(provider) in the notch in light mode")
            #expect(bare.contrast(with: .black) >= floor, "\(provider) on the Screen Bar")
        }
    }

    @Test func anAccentThatAlreadyReadsIsLeftAlone() {
        // Claude's accent reads on a dark tile: the ink is the accent itself.
        let claude = ProviderStyle.style(for: "claude").nsAccent
        #expect(ProviderMarkInk.ink(for: claude, on: .darkPlate) === claude)
        // Grok's grey does not: it is lifted, and stays a grey.
        let grok = Self.rgb(ProviderMarkInk.ink(for: ProviderStyle.style(for: "grok").nsAccent, on: .darkPlate))
        #expect(grok.red > 0.45 && abs(grok.red - grok.blue) < 0.03)
        // Cursor's yellow is deepened on a light tile and keeps its hue.
        let cursor = ProviderMarkInk.ink(for: ProviderStyle.style(for: "cursor").nsAccent, on: .lightPlate)
            .usingColorSpace(.sRGB)
        #expect((cursor?.brightnessComponent ?? 1) < 0.8)
        #expect(abs((cursor?.hueComponent ?? 0) - 48.0 / 360) < 0.01)
    }

    /// `view` through ImageRenderer at 2x, as a bitmap to read back.
    @MainActor static func render(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// A flat swatch through the same pipeline, so the comparison below is
    /// colour-space for colour-space.
    @MainActor static func swatchRed(_ color: NSColor) throws -> CGFloat {
        let rep = try render(Rectangle().fill(Color(nsColor: color)).frame(width: 4, height: 4))
        return rep.colorAt(x: 4, y: 4)?.redComponent ?? -1
    }

    @MainActor @Test func aTileDrawsItsMarkInTheLiftedInk() throws {
        // Grok on a dark tile: the mark is drawn in the lifted grey, not in
        // the accent that vanished there.
        let accent = ProviderStyle.style(for: "grok").nsAccent
        let rep = try Self.render(ProviderTile(style: .style(for: "grok"), size: 32)
            .background(Color(nsColor: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 44 / 255, alpha: 1)))
            .environment(\.colorScheme, .dark))
        let lifted = try Self.swatchRed(ProviderMarkInk.ink(for: accent, on: .darkPlate))
        let raw = try Self.swatchRed(accent)
        var brightest: CGFloat = 0
        var marked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let red = rep.colorAt(x: x, y: y)?.redComponent ?? 0
                brightest = max(brightest, red)
                if red > raw + 0.03 { marked += 1 }
            }
        }
        #expect(lifted > raw + 0.05)
        #expect(abs(brightest - lifted) < 0.02, "the mark's ink \(brightest) is the lifted grey \(lifted)")
        #expect(marked > 40, "\(marked) px are brighter than the old ink could be")
    }
}
