import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Control accessibility", .serialized)
@MainActor
struct ControlsAccessibilityTests {
    @Test func paletteControlsHaveNames() {
        let host = NSHostingView(rootView: PaletteEditor(colors: ["#1288FF"], maximum: 4,
            allowEmpty: true, onChange: { _ in }).frame(width: 400))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(host)
        #expect(labels.contains("Add a colour"))
        #expect(labels.contains("Clear the palette"))
    }

    @Test func deckBankControlsHaveNames() {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-polish-deck.sock")
        let deck = DeckStore(core: core)
        let host = NSHostingView(rootView: BankPager(store: deck).frame(width: 500))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(host)
        #expect(labels.contains("Previous bank"))
        #expect(labels.contains("Next bank"))
    }

}
