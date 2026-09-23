import AppKit
import Foundation
import JRBarLEDS
import Testing
@testable import JRBarApp

/// The Program room's composer sheet: its controls map onto the layer
/// composer one to one, and its default is a light worth starting from.
@Suite("Effect Studio · Compose")
@MainActor
struct EffectStudioComposeTests {
    @Test func theDefaultIsAPlayableBreath() {
        let composed = LEDSComposer.compose(ComposeChoices().composition)
        let analysis = LEDSStudioAnalysis(composed.text)
        #expect(analysis.playable)
        #expect(!analysis.compiled.transformed)
        #expect(composed.text.contains("2400ms pulse"))
        #expect(composed.dropped.isEmpty)
    }

    @Test func choicesMapOntoTheComposition() {
        var choices = ComposeChoices()
        choices.baseKind = .gradient
        choices.baseFrom = "#ff0000"
        choices.baseTo = "#0000FF"
        choices.motion = .roll
        choices.periodSeconds = 3.25
        choices.rollLeftward = true
        choices.accentOn = true
        choices.accentColor = "#FFFFFF"
        choices.accentStepMs = 412.6
        choices.held = [1, 6]
        choices.heldColor = "#00FF00"
        choices.brightness = 0.5
        let composition = choices.composition
        #expect(composition.base == .gradient(RGB8(r: 255, g: 0, b: 0), RGB8(r: 0, g: 0, b: 255)),
                "lowercase hex from a colour well still reads")
        #expect(composition.motion == .roll(periodMs: 3250, leftward: true))
        #expect(composition.accent == .init(color: RGB8(r: 255, g: 255, b: 255), stepMs: 413, leftward: false))
        #expect(composition.overrides == [1: RGB8(r: 0, g: 255, b: 0), 6: RGB8(r: 0, g: 255, b: 0)])
        #expect(composition.brightness == 128)

        choices.accentOn = false
        choices.motion = .steady
        #expect(choices.composition.accent == nil)
        #expect(choices.composition.motion == .steady)
    }

    @Test func theComposeButtonsSymbolExists() {
        #expect(NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil) != nil)
    }
}
